defmodule Tymeslot.Infrastructure.DotenvLoader do
  require Logger

  @moduledoc """
  Populates the system environment from a `.env` file as a fallback for
  shell-supplied variables.

  Shell environment variables always win — values from `.env` are only
  applied to keys that are not already set. This lets operators configure
  releases by dropping a flat `.env` at the release root while still
  allowing one-off shell overrides.

  Invoked at the top of `config/runtime.exs` so the rest of runtime
  configuration sees a populated environment via `System.get_env/1`.
  """

  @doc """
  Loads each `.env` path in order and applies any keys that are not yet
  set in the system environment.

  Missing files are silently skipped — boot must never fail because an
  optional `.env` is absent. Malformed files log a warning and are skipped.
  """
  @spec load([Path.t()]) :: :ok
  def load(paths) when is_list(paths) do
    Enum.each(paths, &load_one/1)
  end

  defp load_one(path) do
    # sys_cmd_fn is disabled to prevent $() shell substitution from executing
    # arbitrary commands as the release user during boot.
    case Dotenvy.source([path],
           side_effect: nil,
           sys_cmd_fn: fn _cmd, _args, _opts -> {"", 1} end
         ) do
      {:ok, vars} ->
        Enum.each(vars, fn {key, value} ->
          if System.get_env(key) == nil, do: System.put_env(key, value)
        end)

      {:error, reason} ->
        Logger.warning("DotenvLoader: skipping malformed .env file", path: path, reason: reason)
    end
  end
end
