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

  # One commit per rendering decision the configs make.
  @commits [
    "fix(core): keep the reconnect prompt until the owner reconnects",
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

      assert changelog =~ "* [BREAKING] Remove the LEGACY_MODE environment variable"
    end

    test "leaves out `saas`-scoped and chore commits", %{repo: repo} do
      changelog = render(repo, "cliff-cloudron.toml")

      refute changelog =~ "pricing page"
      refute changelog =~ "Bump a dependency"
    end
  end

  describe "cliff.toml (the GitHub release notes)" do
    test "writes Core entries without a scope, keeping narrower ones", %{repo: repo} do
      changelog = render(repo, "cliff.toml")

      assert changelog =~ "- Keep the reconnect prompt until the owner reconnects"
      assert changelog =~ "- **security:** Redact secret tokens from request logs"
      refute changelog =~ "core:"
    end

    # Unlike the Cloudron config, this one does not filter by scope, so the
    # handful of `saas`-scoped commits in this history still reach the release
    # notes — and there the prefix earns its place.
    test "keeps a `saas` scope, which still distinguishes something", %{repo: repo} do
      changelog = render(repo, "cliff.toml")

      assert changelog =~ "- **saas:** Add a pricing page"
    end
  end

  defp render(repo, config) do
    git_cliff = System.find_executable("git-cliff")
    config_path = Path.expand("../../#{config}", __DIR__)

    {changelog, 0} = System.cmd(git_cliff, ["--config", config_path], cd: repo, env: [])

    changelog
  end

  # A repository with one empty commit per subject, tagged so git-cliff renders
  # a released section rather than an unreleased one.
  defp build_repo(subjects) do
    repo = Path.join(System.tmp_dir!(), "tymeslot-cliff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)

    git!(repo, ["init", "--quiet"])
    Enum.each(subjects, &git!(repo, ["commit", "--allow-empty", "--no-verify", "-m", &1]))
    git!(repo, ["tag", @tag_name])

    repo
  end

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
