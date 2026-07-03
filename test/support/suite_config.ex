defmodule Tymeslot.Test.SuiteConfig do
  @moduledoc """
  Shared `test_helper.exs` wiring for both umbrella apps.

  Keeps the parallelism sizing, default tag exclusions, and analytics
  completeness gate in one place instead of copy-pasted per app, so the two
  suites can't drift on how many cases they run or which tags they skip.
  """

  # Slow/external suites are opt-in — run them explicitly with `--include`
  # (or `--only`), e.g. `mix test --only e2e`.
  @default_exclude_tags [
    backup_tests: true,
    oauth_integration: true,
    calendar_integration: true,
    e2e: true,
    migrations: true
  ]

  @doc "Default `:exclude` tags every app's suite skips unless explicitly included."
  @spec default_exclude_tags() :: keyword()
  def default_exclude_tags, do: @default_exclude_tags

  @doc """
  Concurrency cap for ExUnit. Honours `TEST_MAX_CASES`, otherwise uses half the
  DB pool size (min 2) to leave headroom for sandbox and multi-repo overhead.
  Returns `nil` when `TEST_MAX_CASES` is set but unparseable, letting the caller
  fall back to the ExUnit default.
  """
  @spec max_cases() :: pos_integer() | nil
  def max_cases do
    case System.get_env("TEST_MAX_CASES") do
      nil ->
        pool_size =
          :tymeslot
          |> Application.get_env(Tymeslot.Repo, [])
          |> Keyword.get(:pool_size, 10)

        max(div(pool_size, 2), 2)

      value ->
        case Integer.parse(value) do
          {int, _rest} -> int
          :error -> nil
        end
    end
  end

  @doc """
  Starts the analytics `collector`, attaches it, and — only under
  `ANALYTICS_COMPLETENESS=1` — registers an after-suite assertion that every
  event in `registry` fired. Partial/focused runs won't exercise every flow, so
  the assertion is gated off for them.
  """
  @spec setup_analytics_completeness(module(), module()) :: :ok
  def setup_analytics_completeness(collector, registry) do
    {:ok, _collector} = collector.start_link()
    collector.attach()

    if System.get_env("ANALYTICS_COMPLETENESS") == "1" do
      ExUnit.after_suite(fn _result ->
        collector.assert_complete!(registry.registry())
        :ok
      end)
    end

    :ok
  end

  @doc """
  Registers an after-suite hook that removes the temp upload directory the run
  wrote avatars/attachments into, so nothing leaks between runs or into the repo.
  """
  @spec cleanup_uploads_after_suite() :: :ok
  def cleanup_uploads_after_suite do
    ExUnit.after_suite(fn _result ->
      case Application.get_env(:tymeslot, :upload_directory) do
        nil -> :ok
        dir -> File.rm_rf(dir)
      end

      :ok
    end)

    :ok
  end
end
