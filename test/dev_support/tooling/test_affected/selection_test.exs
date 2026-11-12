defmodule Tymeslot.TestAffected.SelectionTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  alias Tymeslot.TestAffected.Selection

  # A miniature suite: two auth tests (one of which lives in the web layer, so
  # only the tag can reach it), a payments test, and an untagged plug test.
  defp index(overrides \\ []) do
    tags = %{
      "test/tymeslot/auth/oauth/google_test.exs" => MapSet.new([:auth]),
      "test/tymeslot/auth/session_test.exs" => MapSet.new([:auth, :unit]),
      "test/tymeslot_web/live/login_live_test.exs" => MapSet.new([:auth, :live]),
      "test/tymeslot/payments/stripe_test.exs" => MapSet.new([:payments]),
      "test/tymeslot/payments/refund_test.exs" => MapSet.new([:payments]),
      "test/tymeslot/payments/invoice_test.exs" => MapSet.new([:payments]),
      # Shares the payments directory but not its domain, which is how the
      # mirror-file seed and the mirror-directory seed pull apart.
      "test/tymeslot/payments/ledger_test.exs" => MapSet.new([:analytics]),
      "test/tymeslot/analytics/report_test.exs" => MapSet.new([:analytics]),
      "test/tymeslot_web/plugs/locale_test.exs" => MapSet.new([:plugs])
    }

    base = %{
      test_files: tags |> Map.keys() |> MapSet.new(),
      tags: tags,
      domain_tags: MapSet.new([:auth, :payments, :analytics]),
      sources: %{}
    }

    Enum.into(overrides, base)
  end

  # A suite whose sources name files that are not code: a test reading the
  # Credo config, a module and a test-support helper each reading data, and a
  # module reading data with no test of its own. The zones test shares the
  # payments domain so that sweeping the reader's domain would show.
  defp named_index do
    tags = %{
      "test/tymeslot/auth/session_test.exs" => [:auth],
      "test/tymeslot/payments/stripe_test.exs" => [:payments],
      "test/tymeslot/payments/refund_test.exs" => [:payments],
      "test/tymeslot/analytics/report_test.exs" => [:analytics],
      "test/tymeslot/analytics/funnel_test.exs" => [:analytics],
      "test/tymeslot/analytics/export_test.exs" => [:analytics],
      "test/tymeslot/locale/de_test.exs" => [:i18n],
      "test/tymeslot/timezones/zones_test.exs" => [:payments],
      "test/tymeslot/credo_config_test.exs" => [:analytics]
    }

    sources = %{
      "test/tymeslot/credo_config_test.exs" => ~s|File.read!(".credo.exs")|,
      "test/tymeslot/analytics/funnel_test.exs" => "alias Tymeslot.Test.FixtureHelper",
      "test/support/fixture_helper.ex" =>
        ~s|defmodule Tymeslot.Test.FixtureHelper do\n  @path "priv/fixtures/sample.ics"\nend|,
      "lib/tymeslot/timezones/zones.ex" => ~s|Application.app_dir(:tymeslot, "priv/tz")|,
      "lib/tymeslot/orphan.ex" => ~s|File.read!("priv/orphan_data/rows")|
    }

    %{
      test_files: tags |> Map.keys() |> MapSet.new(),
      tags: Map.new(tags, fn {file, list} -> {file, MapSet.new(list)} end),
      domain_tags: MapSet.new([:auth, :payments, :analytics, :i18n, :dev_support]),
      sources: Map.merge(Map.new(tags, fn {file, _tags} -> {file, ""} end), sources)
    }
  end

  # The consuming repository's suite, with its own cross-repository checks.
  defp downstream_index do
    tags = %{
      "test/tymeslot_saas/billing_test.exs" => [:payments],
      "test/tymeslot_saas/marketing_test.exs" => [:analytics],
      "test/tymeslot_saas/pages_test.exs" => [:analytics],
      "test/tymeslot_saas/blog_test.exs" => [:analytics],
      "test/tymeslot_saas/login_test.exs" => [:auth],
      # A domain the upstream suite does not have, so no upstream tag names it.
      "test/tymeslot_saas/legal_test.exs" => [:legal],
      "test/cross_repo/lock_test.exs" => [:dev_support]
    }

    %{
      test_files: tags |> Map.keys() |> MapSet.new(),
      tags: Map.new(tags, fn {file, list} -> {file, MapSet.new(list)} end),
      domain_tags: MapSet.new([:auth, :payments, :analytics, :i18n, :dev_support, :legal]),
      sources: %{}
    }
  end

  defp downstream_plan(upstream) do
    Selection.plan([], downstream_index(),
      upstream: {upstream, named_index()},
      upstream_tests: "test/cross_repo/"
    )
  end

  describe "classify/1" do
    test "sorts each kind of path into the bucket that decides its blast radius" do
      assert Selection.classify("lib/tymeslot/auth/session.ex") ==
               {:lib, "lib/tymeslot/auth/session.ex"}

      assert Selection.classify("test/tymeslot/auth/session_test.exs") ==
               {:test, "test/tymeslot/auth/session_test.exs"}

      assert Selection.classify("config/runtime.exs") == {:widen, "config/runtime.exs"}
      assert Selection.classify("test/support/factory.ex") == {:widen, "test/support/factory.ex"}
      assert Selection.classify("mix.lock") == {:widen, "mix.lock"}

      assert Selection.classify("priv/repo/migrations/20240101_add_users.exs") ==
               {:migrations, "priv/repo/migrations/20240101_add_users.exs"}

      assert Selection.classify("README.md") == :ignore
      assert Selection.classify("assets/css/app.css") == :ignore
    end

    test "sorts files that are not code by what happens when nothing names them" do
      assert {:translations, _path} = Selection.classify("priv/gettext/de/LC_MESSAGES/default.po")
      assert {:translations, _path} = Selection.classify("priv/gettext/default.pot")

      for path <- ~w[.credo.exs .formatter.exs Dockerfile.docker Dockerfile.dockerignore
                     .githooks/pre-commit scripts/check.sh dev_support/media/seed/demo.exs] do
        assert Selection.classify(path) == {:tooling, path}
      end

      # Compiled code under dev_support/ is still code.
      assert {:lib, _path} = Selection.classify("dev_support/email_testing/tester.ex")
    end

    test "treats anything it does not recognise as data, never ignoring it" do
      assert {:data, _path} = Selection.classify("priv/tz/europe")
      assert {:data, _path} = Selection.classify("some/new/toplevel/thing.exs")
    end

    test "a test file under test/support is support code, not a test to run" do
      assert {:widen, _path} = Selection.classify("test/support/conn_case.ex")
    end
  end

  describe "plan/2 selection" do
    test "a lib change reaches same-domain tests in other directories" do
      plan = Selection.plan(["lib/tymeslot/auth/oauth/google.ex"], index())

      assert plan.scope == :selection
      assert plan.tags == [:auth]

      # The point of the tag sweep: the LiveView test shares the domain but not
      # the directory, so a mirror-path run alone would never reach it.
      assert "test/tymeslot_web/live/login_live_test.exs" in plan.files
      assert "test/tymeslot/auth/session_test.exs" in plan.files

      # ...and it stops at the domain boundary.
      refute "test/tymeslot/payments/stripe_test.exs" in plan.files
      refute "test/tymeslot_web/plugs/locale_test.exs" in plan.files
    end

    test "seeds from the mirror file, so a neighbour's unrelated domain is not swept in" do
      plan = Selection.plan(["lib/tymeslot/payments/stripe.ex"], index())

      assert plan.tags == [:payments]
      assert "test/tymeslot/payments/refund_test.exs" in plan.files

      # `ledger_test.exs` sits in the same directory under a different domain.
      # Seeding from the directory would have adopted `:analytics` and dragged
      # in every analytics test in the suite; seeding from the file does not.
      refute "test/tymeslot/payments/ledger_test.exs" in plan.files
      refute "test/tymeslot/analytics/report_test.exs" in plan.files
    end

    test "a changed test file runs on its own account, whatever it is tagged" do
      plan = Selection.plan(["test/tymeslot_web/plugs/locale_test.exs"], index())

      assert plan.files == ["test/tymeslot_web/plugs/locale_test.exs"]
      assert plan.tags == []
    end

    test "drops a deleted test file instead of naming a path mix test would skip" do
      plan = Selection.plan(["test/tymeslot/auth/removed_test.exs"], index())

      assert plan.scope == :nothing
      assert plan.files == []
    end

    test "ignored paths alone leave nothing to run" do
      plan = Selection.plan(["README.md", "assets/js/app.js"], index())

      assert plan.scope == :nothing
    end
  end

  describe "plan/2 widening" do
    test "one widening path outweighs any amount of successful targeting" do
      plan = Selection.plan(["lib/tymeslot/payments/stripe.ex", "config/runtime.exs"], index())

      assert plan.scope == :full_suite
      assert plan.files == []
      assert Enum.any?(plan.reasons, &(&1 =~ "config/runtime.exs"))
    end

    test "a migration takes the whole suite and the excluded migrations tag with it" do
      plan = Selection.plan(["priv/repo/migrations/20240101_add_users.exs"], index())

      assert plan.scope == :full_suite
      assert plan.include_migrations?
    end

    test "a lib file with no mirror anywhere widens instead of selecting nothing" do
      plan = Selection.plan(["lib/tymeslot/brand_new_thing/widget.ex"], index())

      assert plan.scope == :full_suite
      assert Enum.any?(plan.reasons, &(&1 =~ "no mirror"))
    end

    test "a selection covering half the suite gives up and says why" do
      # :auth reaches three files and :payments three more, which is six of
      # eight: past the point where targeting is worth the risk of missing.
      plan =
        Selection.plan(
          ["lib/tymeslot/auth/session.ex", "lib/tymeslot/payments/stripe.ex"],
          index()
        )

      assert plan.scope == :full_suite
      assert Enum.any?(plan.reasons, &(&1 =~ "of the suite"))
    end
  end

  describe "plan/3 files that are not code" do
    test "a translation catalogue selects the i18n domain, not the whole suite" do
      plan =
        Selection.plan(
          ["priv/gettext/de/LC_MESSAGES/booking.po", "priv/gettext/booking.pot"],
          named_index()
        )

      assert plan.scope == :selection
      assert plan.files == ["test/tymeslot/locale/de_test.exs"]
      assert plan.tags == [:i18n]
    end

    test "a tooling file nothing names selects nothing" do
      plan =
        Selection.plan(
          [".dialyzer_ignore.exs", "Dockerfile.docker", ".githooks/pre-commit"],
          named_index()
        )

      assert plan.scope == :nothing
    end

    test "a tooling file runs the tests that name it" do
      plan = Selection.plan([".credo.exs"], named_index())

      assert plan.files == ["test/tymeslot/credo_config_test.exs"]
    end

    test "a data file a module names runs that module's test, without sweeping its domain" do
      plan = Selection.plan(["priv/tz/europe"], named_index())

      assert plan.files == ["test/tymeslot/timezones/zones_test.exs"]
      refute "test/tymeslot/payments/stripe_test.exs" in plan.files
    end

    test "a data file a test-support module names runs the tests using that module" do
      plan = Selection.plan(["priv/fixtures/sample.ics"], named_index())

      assert plan.files == ["test/tymeslot/analytics/funnel_test.exs"]
    end

    test "a data file nothing names widens" do
      plan = Selection.plan(["priv/unknown/thing.bin"], named_index())

      assert plan.scope == :full_suite
      assert Enum.any?(plan.reasons, &(&1 =~ "not named by any test or module"))
    end

    test "a data file read only by a module with no test widens" do
      plan = Selection.plan(["priv/orphan_data/rows"], named_index())

      assert plan.scope == :full_suite
      assert Enum.any?(plan.reasons, &(&1 =~ "lib/tymeslot/orphan.ex"))
    end
  end

  describe "plan/3 upstream" do
    test "an upstream code change selects this suite's tests in its domains, and the cross-checks" do
      plan = downstream_plan(["lib/tymeslot/payments/stripe.ex"])

      assert plan.scope == :selection

      assert plan.files == [
               "test/cross_repo/lock_test.exs",
               "test/tymeslot_saas/billing_test.exs",
               "test/tymeslot_saas/legal_test.exs"
             ]
    end

    test "an upstream code change selects this suite's domains that no upstream test carries" do
      plan = downstream_plan(["lib/tymeslot/auth/session.ex"])

      assert plan.scope == :selection
      assert "test/tymeslot_saas/legal_test.exs" in plan.files

      assert Enum.any?(
               plan.reasons,
               &(&1 =~ "domains no upstream test carries" and &1 =~ ":legal")
             )
    end

    test "an upstream change that widens there widens here" do
      plan = downstream_plan(["test/support/factory.ex"])

      assert plan.scope == :full_suite
      assert Enum.any?(plan.reasons, &(&1 =~ "upstream test/support/factory.ex"))
    end

    test "an upstream test file reaches only the cross-checks" do
      plan = downstream_plan(["test/tymeslot/payments/stripe_test.exs"])

      assert plan.files == ["test/cross_repo/lock_test.exs"]
    end

    test "an upstream catalogue carries the i18n domain across" do
      index =
        Map.update!(
          downstream_index(),
          :tags,
          &Map.put(&1, "test/tymeslot_saas/blog_test.exs", MapSet.new([:i18n]))
        )

      plan =
        Selection.plan([], index,
          upstream: {["priv/gettext/de/LC_MESSAGES/booking.po"], named_index()}
        )

      # The cross-check and the legal test come from domains the upstream
      # suite does not carry, which any upstream change reaching code selects.
      assert plan.files == [
               "test/cross_repo/lock_test.exs",
               "test/tymeslot_saas/blog_test.exs",
               "test/tymeslot_saas/legal_test.exs"
             ]
    end

    test "upstream changes that cannot reach the build leave nothing to run" do
      assert downstream_plan(["README.md"]).scope == :nothing
    end
  end

  describe "tags_in_source/2" do
    @domain MapSet.new([:auth, :payments])

    test "reads the atom form" do
      assert Selection.tags_in_source("@moduletag :auth\n", @domain) == MapSet.new([:auth])
    end

    test "reads the keyword form the Credo check also accepts" do
      # `@moduletag backup_tests: true` is valid, so a domain tag written that
      # way must not be missed: overlooking it would narrow a selection with no
      # sign that anything was dropped.
      assert Selection.tags_in_source("@moduletag payments: true\n", @domain) ==
               MapSet.new([:payments])
    end

    test "keeps only domain tags, and is not fooled by a tag it does not know" do
      source = "@moduletag :auth\n@moduletag :unit\n@moduletag :not_a_real_tag\n"

      assert Selection.tags_in_source(source, @domain) == MapSet.new([:auth])
    end

    test "a tag inside a one-line string is data, not the module's own" do
      source = """
      @moduletag :payments
      assert tags_in_source("@moduletag :auth\\n") == [:auth]
      """

      assert Selection.tags_in_source(source, @domain) == MapSet.new([:payments])
    end

    test "a tag inside a heredoc is data, not the module's own" do
      source = ~S'''
      @moduletag :payments

      @fixture """
      defmodule SomeTest do
        @moduletag :auth
      end
      """
      '''

      assert Selection.tags_in_source(source, @domain) == MapSet.new([:payments])
    end

    test "an untagged module yields nothing rather than erroring" do
      assert Selection.tags_in_source("defmodule Foo do\nend\n", @domain) == MapSet.new()
    end
  end

  describe "mirror resolution" do
    test "prefers the mirror file, and falls back to the directory without one" do
      assert Selection.mirror_file("lib/tymeslot/auth/session.ex", index()) ==
               "test/tymeslot/auth/session_test.exs"

      assert Selection.mirror_file("lib/tymeslot/auth/no_test_for_this.ex", index()) == nil

      assert {[_first | _rest], "test/tymeslot/auth/"} =
               Selection.mirror("lib/tymeslot/auth/no_test_for_this.ex", index())
    end

    test "refuses to treat a top-level test root as a mirror directory" do
      # `lib/tymeslot/announcements.ex` would otherwise mirror to `test/tymeslot`,
      # which is most of the suite wearing a targeted run's clothes.
      assert Selection.mirror("lib/tymeslot/announcements.ex", index()) == nil
    end

    test "dev tooling and Credo checks mirror into test/dev_support" do
      index =
        index(
          test_files:
            MapSet.new([
              "test/dev_support/tooling/precommit/runner_test.exs",
              "test/dev_support/credo_checks/repo_call_boundary_test.exs"
            ])
        )

      assert Selection.classify("dev_support/tooling/precommit/runner.ex") ==
               {:lib, "dev_support/tooling/precommit/runner.ex"}

      assert Selection.mirror_file("dev_support/tooling/precommit/runner.ex", index) ==
               "test/dev_support/tooling/precommit/runner_test.exs"

      assert Selection.mirror_file("dev_support/credo_checks/repo_call_boundary.ex", index) ==
               "test/dev_support/credo_checks/repo_call_boundary_test.exs"

      assert {["test/dev_support/tooling/precommit/runner_test.exs"],
              "test/dev_support/tooling/precommit/"} =
               Selection.mirror("dev_support/tooling/precommit/guard.ex", index)
    end

    test "a colocated template resolves to its module's test, not one named after itself" do
      assert Selection.mirror_file("lib/tymeslot/auth/session.html.heex", index()) ==
               "test/tymeslot/auth/session_test.exs"
    end
  end
end
