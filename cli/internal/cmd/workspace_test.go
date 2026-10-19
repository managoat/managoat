package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/managoat/managoat/cli/internal/acp"
	"github.com/managoat/managoat/cli/internal/api"
	"github.com/spf13/cobra"
)

const (
	wsUUID      = "0198c9a2-4444-7222-8333-444455556666"
	wsOtherUUID = "0198c9a2-5555-7222-8333-444455556666"
)

// workspaceAPI is a stand-in for /api/workspaces (ADR 0097): two workspaces
// named "shared" and "dup"/"dup", the environment and vault listings for name
// resolution, and a scripted sequence of statuses for GET /workspaces/:id.
type workspaceAPI struct {
	mu       sync.Mutex
	reqs     []recordedRequest
	statuses []string // answered in order by GET /workspaces/<wsUUID>; the last repeats
	reads    int
	failWith map[string]struct {
		status int
		body   string
	} // "METHOD /path" → canned refusal
}

func newWorkspaceAPI(t *testing.T) *workspaceAPI {
	t.Helper()
	w := &workspaceAPI{statuses: []string{"ready"}, failWith: map[string]struct {
		status int
		body   string
	}{}}
	srv := httptest.NewServer(http.HandlerFunc(w.serve(t)))
	t.Cleanup(srv.Close)
	t.Setenv("MANAGOAT_BASE_URL", srv.URL)
	t.Setenv("MANAGOAT_API_KEY", "test-token")
	workspacePollInterval = time.Millisecond
	t.Cleanup(func() { workspacePollInterval = 2 * time.Second })
	return w
}

func (w *workspaceAPI) refuse(method, path string, status int, body string) {
	w.failWith[method+" "+path] = struct {
		status int
		body   string
	}{status, body}
}

func (w *workspaceAPI) serve(t *testing.T) func(http.ResponseWriter, *http.Request) {
	return func(rw http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		if len(raw) > 0 {
			if err := json.Unmarshal(raw, &body); err != nil {
				t.Errorf("request body is not a JSON object: %s", raw)
			}
		}
		w.mu.Lock()
		defer w.mu.Unlock()
		path := r.URL.Path
		if r.URL.RawQuery != "" {
			path += "?" + r.URL.RawQuery
		}
		w.reqs = append(w.reqs, recordedRequest{r.Method, path, body})

		rw.Header().Set("Content-Type", "application/json")
		if f, ok := w.failWith[r.Method+" "+r.URL.Path]; ok {
			rw.WriteHeader(f.status)
			_, _ = io.WriteString(rw, f.body)
			return
		}
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/environments":
			_, _ = io.WriteString(rw, `{"data":[{"id":"`+envUUID+`","name":"base"}]}`)
		case r.Method == http.MethodGet && r.URL.Path == "/api/vaults":
			_, _ = io.WriteString(rw, `{"data":[{"id":"`+vaultUUID+`","name":"creds"}]}`)
		case r.Method == http.MethodGet && r.URL.Path == "/api/agents":
			_, _ = io.WriteString(rw, `{"data":[{"id":"`+agentUUID+`","name":"ada"}]}`)
		case r.Method == http.MethodGet && r.URL.Path == "/api/workspaces":
			_, _ = io.WriteString(rw, `{"data":[`+
				`{"id":"`+wsUUID+`","name":"shared","implicit":false,"status":"ready"},`+
				`{"id":"a","name":"dup","implicit":false,"status":"ready"},`+
				`{"id":"b","name":"dup","implicit":false,"status":"ready"}]}`)
		case r.Method == http.MethodPost && r.URL.Path == "/api/workspaces":
			rw.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(rw, `{"data":{"id":"`+wsUUID+`","name":"shared","status":"provisioning"}}`)
		case r.Method == http.MethodGet && r.URL.Path == "/api/workspaces/"+wsUUID:
			i := w.reads
			if i >= len(w.statuses) {
				i = len(w.statuses) - 1
			}
			w.reads++
			status := w.statuses[i]
			errText := "null"
			if status == "failed" {
				errText = `"setup script exited 1: npm ERR! missing script: build"`
			}
			_, _ = io.WriteString(rw, `{"data":{"id":"`+wsUUID+`","name":"shared","status":"`+status+`","error":`+errText+`,"sandbox_id":null,"sandbox_status":null}}`)
		case r.Method == http.MethodPost && r.URL.Path == "/api/workspaces/"+wsUUID+"/rebuild":
			if body["interrupt"] != true {
				rw.WriteHeader(http.StatusConflict)
				_, _ = io.WriteString(rw, `{"error":"turns_running","message":"a conversation in this workspace is running a turn","conversation_ids":["conv-1"]}`)
				return
			}
			rw.WriteHeader(http.StatusAccepted)
			_, _ = io.WriteString(rw, `{"data":{"id":"`+wsUUID+`","name":"shared","status":"provisioning"}}`)
		case r.Method == http.MethodPost && r.URL.Path == "/api/workspaces/"+wsUUID+"/retry":
			rw.WriteHeader(http.StatusAccepted)
			_, _ = io.WriteString(rw, `{"data":{"id":"`+wsUUID+`","name":"shared","status":"provisioning"}}`)
		case r.Method == http.MethodDelete:
			rw.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodPost && r.URL.Path == "/api/conversations":
			rw.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(rw, `{"data":{"id":"conv-1"}}`)
		default:
			rw.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(rw, `{"error":"not_found"}`)
		}
	}
}

func (w *workspaceAPI) requests() []recordedRequest {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]recordedRequest(nil), w.reqs...)
}

func addWorkspaceCreateFlags(c *cobra.Command) {
	c.Flags().String("environment", "", "")
	c.Flags().String("vault", "", "")
	c.Flags().String("provider", "", "")
	c.Flags().Bool("wait", false, "")
	c.Flags().Duration("timeout", time.Second, "")
	c.Flags().Bool("json", false, "")
}

// Create sends the API's field names, with the environment and vault
// resolved from names, and leaves out what the caller did not name.
func TestWorkspaceCreateSendsTheRequestShape(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want map[string]any
	}{
		{"names resolved", []string{"--environment", "base", "--vault", "creds", "--provider", "e2b"},
			map[string]any{"name": "shared", "environment_id": envUUID, "vault_id": vaultUUID, "sandbox_provider": "e2b"}},
		{"no vault or provider", []string{"--environment", envUUID},
			map[string]any{"name": "shared", "environment_id": envUUID}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorkspaceAPI(t)
			silenceStdout(t)
			cmd := testCmd(t, addWorkspaceCreateFlags, tc.args...)
			if err := workspaceCreate(cmd, "shared"); err != nil {
				t.Fatalf("workspaceCreate: %v", err)
			}
			assertRequest(t, lastWrite(t, w.requests()), http.MethodPost, "/api/workspaces", tc.want)
		})
	}
}

// --wait follows the status until ready, and a failed setup is a non-zero
// exit that carries the workspace's own error.
func TestWorkspaceCreateWaits(t *testing.T) {
	t.Run("ready", func(t *testing.T) {
		w := newWorkspaceAPI(t)
		w.statuses = []string{"provisioning", "provisioning", "ready"}
		silenceStdout(t)
		cmd := testCmd(t, addWorkspaceCreateFlags, "--environment", "base", "--wait")
		if err := workspaceCreate(cmd, "shared"); err != nil {
			t.Fatalf("workspaceCreate --wait: %v", err)
		}
		if w.reads != 3 {
			t.Errorf("read the workspace %d times, want 3", w.reads)
		}
	})

	t.Run("failed", func(t *testing.T) {
		w := newWorkspaceAPI(t)
		w.statuses = []string{"provisioning", "failed"}
		silenceStdout(t)
		cmd := testCmd(t, addWorkspaceCreateFlags, "--environment", "base", "--wait")
		err := workspaceCreate(cmd, "shared")
		if !errors.Is(err, errWorkspaceFailed) {
			t.Fatalf("err = %v, want errWorkspaceFailed", err)
		}
		if !strings.Contains(err.Error(), "missing script: build") {
			t.Errorf("the failure does not carry the workspace's error: %v", err)
		}
	})
}

func TestWaitForWorkspaceTimesOutAndRetriesServerErrors(t *testing.T) {
	t.Run("timeout", func(t *testing.T) {
		w := newWorkspaceAPI(t)
		w.statuses = []string{"provisioning"}
		var progress bytes.Buffer
		_, err := waitForWorkspace(activeClient(), wsUUID, 20*time.Millisecond, &progress)
		if err == nil || !strings.Contains(err.Error(), "still provisioning") {
			t.Fatalf("err = %v, want a timeout naming the status", err)
		}
		if strings.Count(progress.String(), "provisioning") != 1 {
			t.Errorf("progress repeats an unchanged status:\n%s", progress.String())
		}
	})

	t.Run("a 502 is retried", func(t *testing.T) {
		w := newWorkspaceAPI(t)
		w.refuse(http.MethodGet, "/api/workspaces/"+wsUUID, 502, `{"error":"bad_gateway"}`)
		done := make(chan error, 1)
		go func() {
			_, err := waitForWorkspace(activeClient(), wsUUID, 5*time.Second, io.Discard)
			done <- err
		}()
		time.Sleep(20 * time.Millisecond)
		w.mu.Lock()
		delete(w.failWith, http.MethodGet+" /api/workspaces/"+wsUUID)
		w.mu.Unlock()
		if err := <-done; err != nil {
			t.Fatalf("a transient 502 ended the wait: %v", err)
		}
	})

	t.Run("a 404 is not", func(t *testing.T) {
		w := newWorkspaceAPI(t)
		w.refuse(http.MethodGet, "/api/workspaces/"+wsUUID, 404, `{"error":"not_found"}`)
		_, err := waitForWorkspace(activeClient(), wsUUID, 5*time.Second, io.Discard)
		if err == nil || !strings.Contains(err.Error(), "no workspace") {
			t.Fatalf("err = %v, want no workspace", err)
		}
	})
}

func TestWorkspaceListAsksForImplicitOnlyWhenTold(t *testing.T) {
	for _, implicit := range []bool{false, true} {
		w := newWorkspaceAPI(t)
		silenceStdout(t)
		args := []string{}
		if implicit {
			args = append(args, "--implicit")
		}
		cmd := testCmd(t, func(c *cobra.Command) {
			c.Flags().Bool("implicit", false, "")
			c.Flags().Bool("json", false, "")
		}, args...)
		if err := workspaceList(cmd); err != nil {
			t.Fatal(err)
		}
		want := "/api/workspaces"
		if implicit {
			want += "?implicit=true"
		}
		if got := w.requests()[0].Path; got != want {
			t.Errorf("implicit=%v: GET %s, want %s", implicit, got, want)
		}
	}
}

func TestResolveWorkspaceID(t *testing.T) {
	newWorkspaceAPI(t)
	c := activeClient()

	if id, err := resolveWorkspaceID(c, "shared"); err != nil || id != wsUUID {
		t.Errorf("by name: %q, %v", id, err)
	}
	if id, err := resolveWorkspaceID(c, wsOtherUUID); err != nil || id != wsOtherUUID {
		t.Errorf("an id is taken as given: %q, %v", id, err)
	}
	if _, err := resolveWorkspaceID(c, "dup"); err == nil || !strings.Contains(err.Error(), "a, b") {
		t.Errorf("two workspaces with one name must say so and list their ids: %v", err)
	}
	if _, err := resolveWorkspaceID(c, "nope"); err == nil || !strings.Contains(err.Error(), `no workspace named "nope"`) {
		t.Errorf("unknown name: %v", err)
	}
}

func TestWorkspaceDeleteByName(t *testing.T) {
	w := newWorkspaceAPI(t)
	silenceStdout(t)
	if err := workspaceDelete("shared"); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, w.requests()), http.MethodDelete, "/api/workspaces/"+wsUUID, nil)
}

func addWorkspaceRetryFlags(c *cobra.Command) {
	c.Flags().Bool("wait", false, "")
	c.Flags().Duration("timeout", time.Second, "")
	c.Flags().Bool("json", false, "")
}

// Retry posts to the workspace's retry route, by name, with no body; --wait
// follows the setup it started, and a setup that fails again says how to
// retry.
func TestWorkspaceRetry(t *testing.T) {
	t.Run("by name", func(t *testing.T) {
		w := newWorkspaceAPI(t)
		silenceStdout(t)
		if err := workspaceRetry(testCmd(t, addWorkspaceRetryFlags), "shared"); err != nil {
			t.Fatalf("workspaceRetry: %v", err)
		}
		assertRequest(t, lastWrite(t, w.requests()), http.MethodPost, "/api/workspaces/"+wsUUID+"/retry", nil)
		if w.reads != 0 {
			t.Errorf("read the workspace %d times without --wait", w.reads)
		}
	})

	t.Run("wait, ready", func(t *testing.T) {
		w := newWorkspaceAPI(t)
		w.statuses = []string{"provisioning", "ready"}
		silenceStdout(t)
		if err := workspaceRetry(testCmd(t, addWorkspaceRetryFlags, "--wait"), wsUUID); err != nil {
			t.Fatalf("workspaceRetry --wait: %v", err)
		}
		if w.reads != 2 {
			t.Errorf("read the workspace %d times, want 2", w.reads)
		}
	})

	t.Run("wait, failed again", func(t *testing.T) {
		w := newWorkspaceAPI(t)
		w.statuses = []string{"provisioning", "failed"}
		silenceStdout(t)
		err := workspaceRetry(testCmd(t, addWorkspaceRetryFlags, "--wait"), wsUUID)
		if !errors.Is(err, errWorkspaceFailed) {
			t.Fatalf("err = %v, want errWorkspaceFailed", err)
		}
		if !strings.Contains(err.Error(), "managoat workspace retry "+wsUUID) {
			t.Errorf("the failure does not say how to retry: %v", err)
		}
	})

	t.Run("not failed", func(t *testing.T) {
		w := newWorkspaceAPI(t)
		w.refuse(http.MethodPost, "/api/workspaces/"+wsUUID+"/retry", http.StatusConflict,
			`{"error":"workspace_not_failed","message":"the workspace is ready: only a failed workspace's setup can be retried"}`)
		silenceStdout(t)
		err := workspaceRetry(testCmd(t, addWorkspaceRetryFlags), wsUUID)
		if err == nil || !strings.Contains(err.Error(), "managoat workspace wait") {
			t.Fatalf("err = %v, want the workspace_not_failed hint", err)
		}
	})

	t.Run("implicit or another account's", func(t *testing.T) {
		w := newWorkspaceAPI(t)
		w.refuse(http.MethodPost, "/api/workspaces/"+wsUUID+"/retry", http.StatusNotFound, `{"error":"not_found"}`)
		silenceStdout(t)
		err := workspaceRetry(testCmd(t, addWorkspaceRetryFlags), wsUUID)
		if err == nil || !strings.Contains(err.Error(), "no workspace "+wsUUID) {
			t.Fatalf("err = %v, want no workspace", err)
		}
	})
}

// `run --workspace` sends workspace_id beside --cwd, and only when named.
func TestRunBodyCarriesTheWorkspace(t *testing.T) {
	newWorkspaceAPI(t)
	flags := func(c *cobra.Command) {
		c.Flags().String("vault", "", "")
		c.Flags().String("environment", "", "")
		c.Flags().String("cwd", "", "")
		c.Flags().String("workspace", "", "")
		c.Flags().String("client-request-id", "", "")
	}

	body, err := runBody(testCmd(t, flags, "--workspace", "shared", "--cwd", "/home/sprite/api"), "ada", "hi")
	if err != nil {
		t.Fatal(err)
	}
	if body["workspace_id"] != wsUUID || body["cwd"] != "/home/sprite/api" {
		t.Errorf("body = %v", body)
	}
	if _, has := body["environment_id"]; has {
		t.Errorf("an environment was sent that nobody named: %v", body)
	}

	body, err = runBody(testCmd(t, flags), "ada", "hi")
	if err != nil {
		t.Fatal(err)
	}
	if _, has := body["workspace_id"]; has {
		t.Errorf("workspace_id sent without --workspace: %v", body)
	}
}

// `acp --workspace` puts every session's conversation on the workspace.
func TestACPCreateConversationCarriesTheWorkspace(t *testing.T) {
	w := newWorkspaceAPI(t)
	f := acpTestAPI(t, os.Getenv("MANAGOAT_BASE_URL"))
	f.workspace = "shared"
	f.cwd = "/home/sprite/web"
	if _, _, err := f.CreateConversation(context.Background(), agentUUID, acp.SessionOptions{}); err != nil {
		t.Fatal(err)
	}
	got := lastWrite(t, w.requests())
	if got.Body["workspace_id"] != wsUUID || got.Body["cwd"] != "/home/sprite/web" {
		t.Errorf("body = %v", got.Body)
	}
}

// Rebuild names the workspace by name, sends interrupt only when asked, and
// turns a running turn's refusal into the flag that gets past it (#2986).
func TestWorkspaceRebuild(t *testing.T) {
	w := newWorkspaceAPI(t)
	silenceStdout(t)
	flags := func(c *cobra.Command) {
		c.Flags().Bool("interrupt", false, "")
		c.Flags().Bool("wait", false, "")
		c.Flags().Duration("timeout", time.Second, "")
		c.Flags().Bool("json", false, "")
	}
	err := workspaceRebuild(testCmd(t, flags), "shared")
	if err == nil || !strings.Contains(err.Error(), "--interrupt") {
		t.Fatalf("a running turn's refusal = %v, want the --interrupt hint", err)
	}
	if err := workspaceRebuild(testCmd(t, flags, "--interrupt", "--wait"), "shared"); err != nil {
		t.Fatal(err)
	}
	var posts []recordedRequest
	for _, r := range w.requests() {
		if r.Method == http.MethodPost {
			posts = append(posts, r)
		}
	}
	if len(posts) != 2 || posts[0].Path != "/api/workspaces/"+wsUUID+"/rebuild" {
		t.Fatalf("posts = %+v", posts)
	}
	if _, ok := posts[0].Body["interrupt"]; ok {
		t.Errorf("interrupt sent without --interrupt: %v", posts[0].Body)
	}
	if posts[1].Body["interrupt"] != true {
		t.Errorf("--interrupt not sent: %v", posts[1].Body)
	}
}

// A workspace whose machine is behind its environment says so in list and
// show, by field name (#2987); one that matches says nothing.
func TestWorkspaceStaleLabels(t *testing.T) {
	stale := map[string]any{"stale": true, "changed_fields": []any{"setup_script", "env_vars"}}
	if got := workspaceStaleCell(stale); got != "setup_script,env_vars" {
		t.Errorf("list cell = %q", got)
	}
	if got := workspaceStaleLabel(stale); !strings.Contains(got, "setup_script, env_vars") {
		t.Errorf("show label = %q", got)
	}
	fresh := map[string]any{"stale": false, "changed_fields": []any{}}
	if got := workspaceStaleCell(fresh); got != "—" {
		t.Errorf("list cell for a matching machine = %q", got)
	}
	if got := workspaceStaleLabel(fresh); got != "" {
		t.Errorf("show label for a matching machine = %q", got)
	}
	// An older server sends neither field.
	if got := workspaceStaleCell(map[string]any{}); got != "—" {
		t.Errorf("list cell without the fields = %q", got)
	}
}

// The refusals a workspace adds keep the server's words and gain the flag
// that gets past them; any other error is left exactly as it was.
func TestExplainAPIError(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   map[string]any
		hint   string
	}{
		{"fixes environment", 422, map[string]any{"error": "workspace_fixes_environment", "message": "the workspace fixes the environment"}, "drop --environment and --vault"},
		{"sandbox key", 403, map[string]any{"error": "insufficient_scope", "message": "This API key is not permitted to use workspaces", "reason": "insufficient_scope", "required_scope": "full"}, "full-scope key"},
		{"sandbox key, older server", 403, map[string]any{"error": "this API key is not permitted to use workspaces", "reason": "insufficient_scope", "required_scope": "full"}, "full-scope key"},
		{"in use", 409, map[string]any{"error": "source_in_use_by_workspace", "message": "a workspace was created from this"}, "managoat workspace delete"},
		{"retry not failed", 409, map[string]any{"error": "workspace_not_failed", "message": "the workspace is ready"}, "Only a failed workspace"},
		{"allowlist", 422, map[string]any{"error": "environment_not_allowed", "message": "environment is not in the agent's allowed_environment_ids"}, "allowlist applies to a workspace"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := explainAPIError(&api.HTTPError{Status: tc.status, Body: tc.body})
			msg := err.Error()
			if !strings.Contains(msg, tc.hint) {
				t.Errorf("no hint %q in: %s", tc.hint, msg)
			}
			if m, _ := tc.body["message"].(string); m != "" && !strings.Contains(msg, m) {
				t.Errorf("the server's message was lost: %s", msg)
			}
		})
	}

	plain := &api.HTTPError{Status: 500, Body: map[string]any{"error": "boom"}}
	if got := explainAPIError(plain); got != error(plain) {
		t.Errorf("an unrelated error was rewritten: %v", got)
	}
}
