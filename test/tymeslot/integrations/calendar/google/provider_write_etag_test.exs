defmodule Tymeslot.Integrations.Calendar.Google.ProviderWriteEtagTest do
  @moduledoc """
  The etag a write answers with, and whether it survives the conversion.

  `create_event/2` and `update_event/4` are the wrappers the mirror path calls,
  and they differ from the `call_*` functions in one respect nothing else pins:
  they route through `OAuthBase.handle_write_api_call/2`, which keeps the
  provider's etag on the converted event. That etag is the placeholder's version
  marker *as written*, and the only moment it exists outside the provider —
  every etag-based conflict kind is switched off for a provider reporting none.

  The conversion drops it: `convert_event/1` names no etag key. So the merge is
  the whole mechanism, and asserting it against a real provider body rather than
  handing the engine a pre-etagged map is what makes the assertion real.
  Removing the merge left all 610 sync-link tests green, because each supplies
  the etag itself in a shape the write path never produces.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Google.Provider

  setup :verify_on_exit!

  describe "write wrappers keep the provider's etag" do
    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          default_booking_calendar_id: nil
        )

      attrs = %{
        summary: "Busy",
        start_time: ~U[2026-07-03 09:00:00Z],
        end_time: ~U[2026-07-03 10:00:00Z]
      }

      %{integration: integration, attrs: attrs}
    end

    # A real Google write answers with the raw body, string-keyed, etag quoted.
    defp google_body do
      %{
        "id" => "abc123",
        "iCalUID" => "abc123@google.com",
        "etag" => "\"3573625707763998\"",
        "summary" => "Busy",
        "status" => "confirmed",
        "start" => %{"dateTime" => "2026-07-03T09:00:00Z"},
        "end" => %{"dateTime" => "2026-07-03T10:00:00Z"}
      }
    end

    test "create_event carries the etag through onto the converted event", %{
      integration: integration,
      attrs: attrs
    } do
      expect(GoogleCalendarAPIMock, :create_event, fn _int, "primary", _attrs ->
        {:ok, google_body()}
      end)

      assert {:ok, created} = Provider.create_event(integration, attrs)

      # Converted, not raw: `convert_event/1` reads `"id"`, so the write path
      # lands Google's own id under `uid`. The next inbound sync caches
      # `iCalUID || id` instead — the suffixed form — which is exactly why the
      # mirror set has to carry both and why matching on `target_uid` alone
      # recognised none of its own placeholders.
      assert created.uid == "abc123"

      # De-quoted by `WriteEtag.normalise/1`, so it compares equal against the
      # cache column the same function populates.
      assert created.etag == "3573625707763998"
    end

    test "update_event carries the etag through onto the converted event", %{
      integration: integration,
      attrs: attrs
    } do
      expect(GoogleCalendarAPIMock, :update_event, fn _int, "primary", "abc123", _attrs ->
        {:ok, google_body()}
      end)

      assert {:ok, updated} = Provider.update_event(integration, "abc123", attrs)

      assert updated.etag == "3573625707763998"
    end

    test "a provider response carrying no etag leaves the converted event without one", %{
      integration: integration,
      attrs: attrs
    } do
      expect(GoogleCalendarAPIMock, :create_event, fn _int, "primary", _attrs ->
        {:ok, Map.delete(google_body(), "etag")}
      end)

      assert {:ok, created} = Provider.create_event(integration, attrs)

      # Absent rather than nil: the engine stores what it is handed, and a
      # fabricated baseline would make a stranger's edit compare equal.
      refute Map.has_key?(created, :etag)
    end
  end
end
