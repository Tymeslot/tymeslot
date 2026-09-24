defmodule Tymeslot.Release.ChangelogConfigsTest do
  @moduledoc """
  Renders the real git-cliff configs over a throwaway repository.

  The two configs are release tooling with no compile-time surface: nothing
  catches a broken template until a release is already being cut, and the
  Cloudron one feeds the update prompt operators read. Rendering a repository
  we build here exercises both halves that can break — the commit parsers
  (which scope and type reach the changelog) and the body template (how each
  entry is written) — without depending on this repository's own history.
  """
  use ExUnit.Case, async: true

  @moduletag :utils
  @moduletag :git_cliff

  # One commit per rendering decision the configs make. The `core` and `saas`
  # scopes are retired and refused at commit time, but they run throughout the
  # history before that change, so both configs still have to render them.
  @commits [
    "fix(core): keep the reconnect prompt until the owner reconnects",
    {"fix(core)!: read config files strictly",
     "BREAKING CHANGE: values are no longer interpolated.\nWrite the final value out."},
    "fix(security): redact secret tokens from request logs",
    "fix: fall back to UTC when a profile has no timezone set",
    "feat(core)!: remove the LEGACY_MODE environment variable",
    "feat(saas): add a pricing page",
    "chore(core): bump a dependency"
  ]

  @tag_name "v1.0.0"

  setup do
    {:ok, repo: build_repo(@commits)}
  end

  describe "cliff-cloudron.toml (the Cloudron update prompt)" do
    test "writes Core entries without a scope, keeping narrower ones", %{repo: repo} do
      changelog = render(repo, "cliff-cloudron.toml")

      assert changelog =~ "* Keep the reconnect prompt until the owner reconnects"
      assert changelog =~ "* security: Redact secret tokens from request logs"
      assert changelog =~ "* Fall back to UTC when a profile has no timezone set"
      refute changelog =~ "core:"
    end

    test "marks a breaking change without reintroducing the scope", %{repo: repo} do
      changelog = render(repo, "cliff-cloudron.toml")

      assert changelog =~ "* [BREAKING] Remove the LEGACY_MODE environment variable\n"
    end

    # The update prompt keeps only `[BREAKING]` lines once a release has curated
    # highlights, so the migration note must sit on that line to survive.
    test "keeps a breaking change's migration note on its [BREAKING] line", %{repo: repo} do
      changelog = render(repo, "cliff-cloudron.toml")

      assert changelog =~
               "* [BREAKING] Read config files strictly: values are no longer interpolated. " <>
                 "Write the final value out.\n"
    end

    test "leaves out `saas`-scoped and chore commits", %{repo: repo} do
      changelog = render(repo, "cliff-cloudron.toml")

      refute changelog =~ "pricing page"
      refute changelog =~ "Bump a dependency"
    end
  end

  describe "cliff.toml (the GitHub release notes)" do
    test "writes entries without a retired scope, keeping narrower ones", %{repo: repo} do
      changelog = render(repo, "cliff.toml")

      assert changelog =~ "- Keep the reconnect prompt until the owner reconnects"
      assert changelog =~ "- **security:** Redact secret tokens from request logs"
      refute changelog =~ "core:"
    end

    # Unlike the Cloudron config, this one does not filter by scope, so a
    # `saas`-scoped commit from before the retirement still reaches the release
    # notes. The entry is kept; only the prefix, which named a repository
    # rather than anything about the change, is dropped.
    test "suppresses a retired `saas` scope without dropping the entry", %{repo: repo} do
      changelog = render(repo, "cliff.toml")

      assert changelog =~ "- Add a pricing page"
      refute changelog =~ "saas:"
    end

    test "follows a breaking change with its migration note", %{repo: repo} do
      changelog = render(repo, "cliff.toml")

      assert changelog =~
               "- Read config files strictly: values are no longer interpolated. " <>
                 "Write the final value out.\n"

      assert changelog =~ "- Remove the LEGACY_MODE environment variable\n"
    end
  end

  defp render(repo, config) do
    git_cliff = System.find_executable("git-cliff")
    config_path = Path.expand("../../#{config}", __DIR__)

    # git-cliff logs a new-release notice at info level on every run, which
    # would otherwise land in the middle of the suite's output.
    {changelog, 0} =
      System.cmd(git_cliff, ["--config", config_path], cd: repo, env: [{"RUST_LOG", "warn"}])

    changelog
  end

  # A repository with one empty commit per message, tagged so git-cliff renders
  # a released section rather than an unreleased one. A `{subject, body}` pair
  # becomes a commit with a body, which is where a `BREAKING CHANGE:` footer
  # lives.
  defp build_repo(messages) do
    repo = Path.join(System.tmp_dir!(), "tymeslot-cliff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)

    git!(repo, ["init", "--quiet"])

    Enum.each(
      messages,
      &git!(repo, ["commit", "--allow-empty", "--no-verify" | message_args(&1)])
    )

    git!(repo, ["tag", @tag_name])

    repo
  end

  defp message_args({subject, body}), do: ["-m", subject, "-m", body]
  defp message_args(subject), do: ["-m", subject]

  # Identity and signing come from flags rather than the environment, so the
  # test does not depend on (or write to) the developer's git configuration.
  defp git!(repo, args) do
    identity = [
      "-c",
      "user.name=Tymeslot Test",
      "-c",
      "user.email=test@example.com",
      "-c",
      "commit.gpgsign=false"
    ]

    {output, 0} = System.cmd("git", identity ++ args, cd: repo, env: [], stderr_to_stdout: true)
    output
  end
end
