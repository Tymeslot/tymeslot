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
      domain_tags: MapSet.new([:auth, :payments, :analytics])
    }

    Enum.into(overrides, base)
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

    test "widens on anything it does not recognise, rather than ignoring it" do
      assert {:widen, _path} = Selection.classify("priv/gettext/de/LC_MESSAGES/default.po")
      assert {:widen, _path} = Selection.classify("some/new/toplevel/thing.exs")
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

    test "a colocated template resolves to its module's test, not one named after itself" do
      assert Selection.mirror_file("lib/tymeslot/auth/session.html.heex", index()) ==
               "test/tymeslot/auth/session_test.exs"
    end
  end
end
