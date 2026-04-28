Code.require_file(
  "dev_support/credo_checks/no_inline_caldav_list.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoInlineCaldavListTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoInlineCaldavList

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged: atom list" do
    test "flags inline atom list with caldav and radicale" do
      """
      defmodule Tymeslot.Sync do
        def providers, do: [:caldav, :radicale, :nextcloud, :zimbra]
      end
      """
      |> to_source_file("lib/tymeslot/sync.ex")
      |> run_check(NoInlineCaldavList)
      |> assert_issue(fn issue -> assert issue.trigger == "caldav-list" end)
    end
  end

  describe "flagged: string list" do
    test "flags inline string list with caldav and radicale" do
      """
      defmodule Tymeslot.Sync do
        def provider_strings, do: ["caldav", "radicale", "nextcloud", "zimbra"]
      end
      """
      |> to_source_file("lib/tymeslot/sync.ex")
      |> run_check(NoInlineCaldavList)
      |> assert_issue(fn issue -> assert issue.trigger == "caldav-list" end)
    end
  end

  describe "flagged: sigil list" do
    test "flags ~w(...) sigil with caldav and radicale" do
      """
      defmodule Tymeslot.Sync do
        def providers, do: ~w(caldav radicale nextcloud zimbra)
      end
      """
      |> to_source_file("lib/tymeslot/sync.ex")
      |> run_check(NoInlineCaldavList)
      |> assert_issue(fn issue -> assert issue.trigger == "caldav-list" end)
    end

    test "flags ~w{...} sigil (curly-brace delimiter)" do
      """
      defmodule Tymeslot.Sync do
        def providers, do: ~w{caldav radicale nextcloud zimbra}
      end
      """
      |> to_source_file("lib/tymeslot/sync.ex")
      |> run_check(NoInlineCaldavList)
      |> assert_issue(fn issue -> assert issue.trigger == "caldav-list" end)
    end
  end

  describe "not flagged: comment lines" do
    test "does not flag a comment mentioning caldav and radicale" do
      """
      defmodule Tymeslot.Sync do
        # Supports :caldav and :radicale providers.
        def providers, do: []
      end
      """
      |> to_source_file("lib/tymeslot/sync.ex")
      |> run_check(NoInlineCaldavList)
      |> refute_issues()
    end
  end

  describe "not flagged: typespec lines" do
    test "does not flag a @type declaration with caldav and radicale" do
      """
      defmodule Tymeslot.Sync do
        @type provider :: :caldav | :radicale | :nextcloud | :zimbra
      end
      """
      |> to_source_file("lib/tymeslot/sync.ex")
      |> run_check(NoInlineCaldavList)
      |> refute_issues()
    end
  end

  describe "not flagged: whitelisted files" do
    test "does not flag provider_config.ex even with an inline list" do
      """
      defmodule Tymeslot.Integrations.Calendar.ProviderConfig do
        def caldav_based_providers, do: [:caldav, :radicale, :nextcloud, :zimbra]
      end
      """
      |> to_source_file("lib/tymeslot/integrations/calendar/providers/provider_config.ex")
      |> run_check(NoInlineCaldavList)
      |> refute_issues()
    end

    test "does not flag provider_registry.ex even with an inline list" do
      """
      defmodule Tymeslot.Integrations.Calendar.ProviderRegistry do
        @providers [:caldav, :radicale, :nextcloud, :zimbra]
      end
      """
      |> to_source_file("lib/tymeslot/integrations/calendar/providers/provider_registry.ex")
      |> run_check(NoInlineCaldavList)
      |> refute_issues()
    end

    test "does not flag docs_live/articles.ex even with provider tokens" do
      """
      defmodule TymeslotSaasWeb.DocsLive.Articles do
        @tags ~w(caldav radicale nextcloud zimbra)
      end
      """
      |> to_source_file("lib/tymeslot_saas_web/live/docs_live/articles.ex")
      |> run_check(NoInlineCaldavList)
      |> refute_issues()
    end
  end

  describe "not flagged: excluded paths" do
    test "does not flag test files" do
      """
      defmodule Tymeslot.SyncTest do
        def providers, do: [:caldav, :radicale, :nextcloud, :zimbra]
      end
      """
      |> to_source_file("test/tymeslot/sync_test.exs")
      |> run_check(NoInlineCaldavList)
      |> refute_issues()
    end

    test "does not flag migration files" do
      """
      defmodule Tymeslot.Repo.Migrations.SeedProviders do
        @providers [:caldav, :radicale, :nextcloud, :zimbra]
      end
      """
      |> to_source_file("priv/repo/migrations/20260101000000_seed_providers.exs")
      |> run_check(NoInlineCaldavList)
      |> refute_issues()
    end
  end
end
