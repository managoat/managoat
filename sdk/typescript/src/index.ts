export {
  Managoat,
  type ManagoatOptions,
  type RunConfig,
  // Deprecated aliases from before ADR 0082 renamed the project.
  Fountain,
  type FountainOptions,
} from "./client.ts";
export { Run, type RunOptions } from "./run.ts";
export { Conversation, type HistoryOptions, type SendOptions } from "./conversation.ts";
export { HttpClient, type FetchLike, type RequestOptions } from "./http.ts";
export { Agents, Connections, Environments, Vaults, Workspaces, type WaitForReadyOptions } from "./resources.ts";
export {
  resolveConfig,
  conversationUrl,
  DEFAULT_BASE_URL,
  DEFAULT_APP_URL,
  type ConfigOptions,
  type ResolvedConfig,
} from "./config.ts";
export { streamEvents, streamPath, parseSse, type StreamOptions, type SseMessage } from "./sse.ts";
export { TurnFollower } from "./turn.ts";
export {
  ManagoatError,
  FountainError,
  AuthError,
  NotFoundError,
  ValidationError,
  RateLimitError,
  ConversationBusyError,
  NotReadyError,
  ConnectionError,
  TimeoutError,
  ResolutionError,
  WorkspaceFailedError,
  type ManagoatErrorCode,
  type FountainErrorCode,
} from "./errors.ts";
export type * from "./schemas.ts";
export type {
  AccountEvent,
  AccountLogEvent,
  Agent,
  AgentInput,
  Block,
  ConversationRecord,
  ConversationStatus,
  Environment,
  EnvironmentInput,
  LogEvent,
  McpConnection,
  McpConnectionInput,
  McpConnectionLogin,
  NamedResource,
  PermissionOption,
  PermissionRequest,
  ElicitationAnswer,
  ElicitationRequest,
  ElicitationValue,
  Stream,
  Repository,
  Runtime,
  RunEvent,
  RunResult,
  SandboxChange,
  SandboxDiff,
  SandboxEntry,
  SandboxFile,
  SandboxListing,
  SandboxProvider,
  SandboxRecord,
  SandboxStatus,
  Secret,
  SkillInput,
  Turn,
  TurnState,
  Vault,
  VaultInput,
  VaultSecretMetadataPatch,
  Workspace,
  WorkspaceInput,
  WorkspaceStatusEvent,
  ConversationsChangedEvent,
} from "./types.ts";

import { Managoat } from "./client.ts";
export default Managoat;
