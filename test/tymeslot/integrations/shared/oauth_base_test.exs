defmodule Tymeslot.Integrations.Common.OAuthBaseTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Common.OAuthBase

  describe "validate_config/2" do
    test "validates required fields" do
      config = %{
        access_token: "at",
        refresh_token: "rt",
        token_expires_at: DateTime.utc_now(),
        oauth_scope: "scope"
      }

      assert :ok = OAuthBase.validate_config(config, fn _client -> :ok end)

      assert {:error, message} = OAuthBase.validate_config(%{}, fn _client -> :ok end)
      assert message =~ "Missing required fields"
    end

    test "calls scope validator if fields are present" do
      config = %{
        access_token: "at",
        refresh_token: "rt",
        token_expires_at: DateTime.utc_now(),
        oauth_scope: "scope"
      }

      assert {:error, "invalid scope"} =
               OAuthBase.validate_config(config, fn _client -> {:error, "invalid scope"} end)
    end
  end

  describe "new/2" do
    test "returns ok tuple on success" do
      config = %{
        access_token: "at",
        refresh_token: "rt",
        token_expires_at: DateTime.utc_now(),
        oauth_scope: "scope"
      }

      assert {:ok, ^config} = OAuthBase.new(config, fn _client -> :ok end)
    end

    test "returns error on failure" do
      assert {:error, _reason} = OAuthBase.new(%{}, fn _client -> :ok end)
    end
  end

  describe "time helpers" do
    test "default_start_time/0 returns a time in the past" do
      now = DateTime.utc_now()
      start = OAuthBase.default_start_time()
      assert DateTime.compare(start, now) == :lt
    end

    test "default_end_time/0 returns a time in the future" do
      now = DateTime.utc_now()
      finish = OAuthBase.default_end_time()
      assert DateTime.compare(finish, now) == :gt
    end
  end

  describe "handle_api_call/2" do
    test "handles ok results" do
      assert {:ok, "RESULT"} =
               OAuthBase.handle_api_call(fn -> {:ok, "result"} end, &String.upcase/1)

      assert :ok = OAuthBase.handle_api_call(fn -> :ok end)
    end

    test "handles error results" do
      assert {:error, "reason"} = OAuthBase.handle_api_call(fn -> {:error, "reason"} end)
    end

    # Callers above this layer dispatch on the atom: CalendarEventSync recreates
    # an event on :not_found, CalendarEventWorker discards on :unauthorized.
    # Returning the provider's message instead made those branches unreachable.
    test "keeps the classification atom from a typed provider error" do
      assert {:error, :not_found} =
               OAuthBase.handle_api_call(fn -> {:error, :not_found, "Event not found"} end)

      assert {:error, :unauthorized} =
               OAuthBase.handle_api_call(fn ->
                 {:error, :unauthorized, "Token expired or invalid"}
               end)
    end
  end

  # The producing half of the mirror's etag baseline. `SyncLink.Engine`'s tests
  # mock `Tymeslot.CalendarMock` at `create_event`/`update_event`, which sits
  # *above* this module — they prove the engine consumes an etag correctly, but
  # they cannot reach the code that captures one. Deleting the merge below left
  # all 334 of those tests green while the three etag-based conflict kinds
  # silently stopped firing, which is the exact state this mechanism exists to
  # prevent. So the capture is pinned here, at the layer that performs it.
  #
  # The conversion functions are the providers' real `convert_event/1`, not
  # stubs. A stub would be free to carry an etag through, and the whole reason
  # this wrapper exists is that the real ones do not: they name a fixed set of
  # keys and drop everything else, the etag included.
  describe "handle_write_api_call/2" do
    alias Tymeslot.Integrations.Calendar.Google
    alias Tymeslot.Integrations.Calendar.Outlook

    # A Google write response as the API module hands it up: the decoded JSON
    # body, string-keyed, with the etag quoted as an HTTP entity tag.
    defp google_body(attrs \\ %{}) do
      Map.merge(
        %{
          "id" => "google-event-id",
          "etag" => "\"3573625707763998\"",
          "summary" => "Busy",
          "status" => "confirmed"
        },
        attrs
      )
    end

    test "keeps Google's etag on the converted event" do
      assert {:ok, converted} =
               OAuthBase.handle_write_api_call(
                 fn -> {:ok, google_body()} end,
                 &Google.Provider.convert_event/1
               )

      assert converted.etag == "3573625707763998"

      # The conversion itself is untouched: the wrapper adds a key, it does not
      # replace what `convert_event/1` produced.
      assert converted.uid == "google-event-id"
      assert converted.summary == "Busy"
    end

    test "keeps Outlook's @odata.etag on the converted event" do
      # Graph's own key, on the raw body Outlook's API module answers with.
      raw = %{
        "@odata.etag" => "W/\"CQAAABYAAAD\"",
        id: "outlook-event-id",
        summary: "Busy"
      }

      assert {:ok, converted} =
               OAuthBase.handle_write_api_call(
                 fn -> {:ok, raw} end,
                 &Outlook.Provider.convert_event/1
               )

      assert converted.etag == EventProcessor.clean_etag("W/\"CQAAABYAAAD\"")
      assert converted.uid == "outlook-event-id"
    end

    test "leaves no :etag key at all when the provider reported none" do
      # Absence rather than `nil`, and the distinction is load-bearing:
      # `WriteEtag.extract/1` matches on `%{etag: etag}`, so a key present and
      # `nil` is a report of "no etag" that had to travel one clause further
      # than one that was never added. Asserting `== nil` would pass under a
      # merge that fabricates the key, which is what this forbids.
      raw = Map.delete(google_body(), "etag")

      assert {:ok, converted} =
               OAuthBase.handle_write_api_call(
                 fn -> {:ok, raw} end,
                 &Google.Provider.convert_event/1
               )

      refute Map.has_key?(converted, :etag)
      assert converted.uid == "google-event-id"
    end

    test "leaves no :etag key when the provider reported a blank one" do
      # `""` is a provider reporting nothing. Merging it would store a baseline
      # no real etag can ever equal, turning every subsequent pass into a
      # conflict — the false-positive flood, arrived at from the other side.
      assert {:ok, converted} =
               OAuthBase.handle_write_api_call(
                 fn -> {:ok, google_body(%{"etag" => "\"\""})} end,
                 &Google.Provider.convert_event/1
               )

      refute Map.has_key?(converted, :etag)
    end

    test "passes a bare :ok through unchanged" do
      # The CalDAV shape. There is no response to read an etag from and none may
      # be invented, so the result is exactly what `handle_api_call/2` gives.
      assert :ok ==
               OAuthBase.handle_write_api_call(
                 fn -> :ok end,
                 &Google.Provider.convert_event/1
               )
    end

    test "returns a non-map conversion untouched rather than coercing it" do
      # A conversion answering something other than a map has nowhere to put a
      # key, and inventing a wrapper map to hold one would hand every caller a
      # shape its provider never produced.
      assert {:ok, "RESULT"} ==
               OAuthBase.handle_write_api_call(
                 fn -> {:ok, %{"etag" => "\"ignored\"", "value" => "result"}} end,
                 fn raw -> String.upcase(raw["value"]) end
               )
    end

    test "handles error results exactly as handle_api_call/2 does" do
      # The write wrapper differs from the read one only on success. Every
      # caller above dispatches on the classification atom, so a divergence in
      # the error clauses would be a second contract to keep in step.
      assert {:error, "reason"} ==
               OAuthBase.handle_write_api_call(
                 fn -> {:error, "reason"} end,
                 &Google.Provider.convert_event/1
               )

      assert {:error, :not_found} ==
               OAuthBase.handle_write_api_call(
                 fn -> {:error, :not_found, "Event not found"} end,
                 &Google.Provider.convert_event/1
               )

      assert {:error, :unauthorized} ==
               OAuthBase.handle_write_api_call(
                 fn -> {:error, :unauthorized, "Token expired or invalid"} end,
                 &Google.Provider.convert_event/1
               )
    end
  end

  describe "create_or_update_integration/4" do
    test "creates a new integration if none exists" do
      user = insert(:user)
      insert(:profile, user: user)

      tokens = %{
        access_token: "at",
        refresh_token: "rt",
        expires_at: DateTime.utc_now(),
        scope: "scope"
      }

      assert {:ok, integration} =
               OAuthBase.create_or_update_integration(
                 user.id,
                 "google",
                 %{name: "My Cal", base_url: "https://google.com"},
                 tokens
               )

      assert integration.user_id == user.id
      assert integration.provider == "google"

      # Decrypt to check virtual fields
      integration =
        CalendarIntegrationSchema.decrypt_oauth_tokens(integration)

      assert integration.access_token == "at"
    end

    test "updates existing integration" do
      user = insert(:user)
      insert(:profile, user: user)

      existing =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token: "old",
          base_url: "https://google.com"
        )

      tokens = %{
        access_token: "new",
        refresh_token: "rt",
        expires_at: DateTime.utc_now(),
        scope: "scope"
      }

      assert {:ok, updated} =
               OAuthBase.create_or_update_integration(user.id, "google", %{}, tokens)

      assert updated.id == existing.id

      # Decrypt to check virtual fields
      updated = CalendarIntegrationSchema.decrypt_oauth_tokens(updated)
      assert updated.access_token == "new"
    end
  end
end
