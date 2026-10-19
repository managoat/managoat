defmodule FountainWeb.EnvironmentJSON do
  @moduledoc false
  alias Fountain.Environments.Environment

  def index(%{environments: envs}), do: %{data: Enum.map(envs, &data/1)}
  def show(%{environment: env}), do: %{data: data(env)}

  def data(%Environment{} = env) do
    %{
      id: env.id,
      name: env.name,
      packages: env.packages,
      env_vars: env.env_vars,
      setup_script: env.setup_script,
      setup_timeout_seconds: env.setup_timeout_seconds,
      networking_type: env.networking_type,
      networking_config: env.networking_config,
      repositories: env.repositories,
      metadata: env.metadata,
      # The revision a workspace's machine is compared with (#2987).
      revision: env.revision,
      secret_count: env.secret_count,
      agent_count: env.agent_count,
      inserted_at: env.inserted_at,
      updated_at: env.updated_at
    }
  end
end
