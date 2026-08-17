defmodule Tymeslot.Integrations.Calendar.Outlook.ProviderWriteEtagTest do
  @moduledoc """
  The etag an Outlook write answers with, and whether it survives the API
  module's own narrowing.

  This is the Outlook counterpart of `Google.ProviderWriteEtagTest`, and it
  exists because the two providers preserve the write response differently.
  Google's API module answers with the **raw** body
  (`google_calendar_api.ex:113`), so `OAuthBase.handle_write_api_call/2` still
  sees `"etag"` when it merges. Outlook's answers
  `List.first(convert_to_common_format([response]))`
  (`outlook_calendar_api.ex:103`), and `convert_to_common_format/1`
  (`outlook_calendar_api.ex:496-511`) builds a fixed atom-keyed map naming ten
  keys, none of them an etag. So Graph's `@odata.etag` was dropped one layer
  *below* the wrapper that was supposed to keep it.

  `OAuthBaseTest` asserted the opposite and stayed green, because it called
  `handle_write_api_call/2` directly with a hand-built map carrying
  `"@odata.etag"` — a shape the API module never produces. Mocking the API
  module instead, as this does, is what makes the assertion real: the mock
  returns what `create_event/2` actually returns, and the narrowing under test
  is the production one.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.Provider
  alias Tymeslot.SyncLinkTestHelpers

  setup :verify_on_exit!

  describe "write wrappers keep the provider's etag" do
    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          default_booking_calendar_id: nil
        )

      attrs = %{
        summary: "Busy",
        start_time: ~U[2026-07-03 09:00:00Z],
        end_time: ~U[2026-07-03 10:00:00Z]
      }

      %{integration: integration, attrs: attrs}
    end

    test "create_event carries the etag through onto the converted event", %{
      integration: integration,
      attrs: attrs
    } do
      expect(OutlookCalendarAPIMock, :create_event, fn _int, _attrs ->
        {:ok, SyncLinkTestHelpers.outlook_write_response()}
      end)

      assert {:ok, created} = Provider.create_event(integration, attrs)

      # `convert_event/1` reads `[:id]` first, so Graph's own event id lands
      # under `uid` — the same identity the inbound sync caches, since Outlook
      # (unlike Google) does not re-mint the UID it was handed.
      assert created.uid == "AAMkAGI2TG93AAA="

      # Weak-tag quoting trimmed by the one cleaner both sides share, so this
      # compares equal against the cache column populated through it.
      assert created.etag == "W/\"CQAAABYAAADXbZ3"
    end

    test "update_event carries the etag through onto the converted event", %{
      integration: integration,
      attrs: attrs
    } do
      expect(OutlookCalendarAPIMock, :update_event, fn _int, "AAMkAGI2TG93AAA=", _attrs ->
        {:ok, SyncLinkTestHelpers.outlook_write_response()}
      end)

      assert {:ok, updated} = Provider.update_event(integration, "AAMkAGI2TG93AAA=", attrs)

      assert updated.etag == "W/\"CQAAABYAAADXbZ3"
    end

    test "a write response carrying no etag leaves the converted event without one", %{
      integration: integration,
      attrs: attrs
    } do
      expect(OutlookCalendarAPIMock, :create_event, fn _int, _attrs ->
        {:ok, Map.delete(SyncLinkTestHelpers.outlook_write_response(), :etag)}
      end)

      assert {:ok, created} = Provider.create_event(integration, attrs)

      # Absent rather than nil: a fabricated baseline compares unequal to every
      # real etag and would turn every sweep into a conflict.
      refute Map.has_key?(created, :etag)
    end
  end

  describe "the API module's own narrowing" do
    # The defect site itself. Everything above mocks the API module and so
    # takes the narrowing on trust; this feeds the raw Graph body to the
    # function that narrows it, which is the only layer where `@odata.etag`
    # ever exists. Without this, teaching the fixture an `:etag` key would make
    # the wrapper tests pass over a value production never produced — the exact
    # failure mode that kept `OAuthBaseTest`'s Outlook case green.
    test "convert_to_common_format/1 keeps Graph's @odata.etag" do
      raw = SyncLinkTestHelpers.outlook_graph_write_body()

      assert [narrowed] = CalendarAPI.convert_to_common_format([raw])

      assert narrowed.etag == "W/\"CQAAABYAAADXbZ3\""
      assert narrowed.id == "AAMkAGI2TG93AAA="
    end

    test "an entity Graph annotated with no etag narrows to a nil one" do
      raw = Map.delete(SyncLinkTestHelpers.outlook_graph_write_body(), "@odata.etag")

      assert [narrowed] = CalendarAPI.convert_to_common_format([raw])

      # `WriteEtag.extract/1` normalises a nil through `clean_etag/1`, which
      # answers nil for a non-binary, so no baseline is stamped and the
      # etag-based kinds stay off rather than comparing against a fiction.
      assert narrowed.etag == nil
    end
  end
end
