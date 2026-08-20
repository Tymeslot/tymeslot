defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPIInstanceIdTest do
  @moduledoc """
  The write paths, and the id-mapping trap `get_event/3` already avoids.

  Google expresses one occurrence of a recurring series as an instance id:
  `{masterId}_{YYYYMMDD}T{HHMMSS}Z`. It is an id Google minted, and it is the
  id `list_events/4` returns for that occurrence — so it is the id every caller
  holds when it wants to write to one.

  It is not base32hex. The underscore, the `T` and the `Z` all sit outside
  `a-v0-9`, so `uuid_to_google_event_id/1` used to hash the whole string: the
  real instance `56km0ibouqobmlmh3g5ptdmp28_20260904T140000Z` became
  `3k00t2b8doud77raa00g0mapusod4t7o`, and the DELETE addressed an event that
  has never existed. Measured live against the organiser's calendar, twice:
  `list_events` returned the instance, `delete_event` answered
  `{:error, :not_found, "Event not found"}`, and the occurrence survived.

  On a mirrored series that is a cancelled occurrence that is never withdrawn
  from the target calendar, going on blocking a slot nobody can book.

  `get_event/3` was already exempt and documents why. These tests hold the
  three write paths to the same rule, and the last one holds the create path to
  the opposite one: a UID *we* minted still has to be converted, or every
  placeholder write breaks instead.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Google.EventMapper
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  # A real instance id, copied from the organiser's calendar, of the series
  # whose cancelled occurrence failed to withdraw.
  @instance_id "56km0ibouqobmlmh3g5ptdmp28_20260904T140000Z"

  setup do
    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        access_token_encrypted: Encryption.encrypt("valid_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      )

    %{integration: integration}
  end

  describe "an id Google minted survives the write paths" do
    test "delete_event/3 addresses the instance verbatim", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url ==
                 "https://www.googleapis.com/calendar/v3/calendars/primary/events/#{@instance_id}"

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = CalendarAPI.delete_event(integration, "primary", @instance_id)
    end

    test "update_event/4 addresses the instance verbatim", %{integration: integration} do
      event_data = %{
        summary: "Busy",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600),
        timezone: "UTC"
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :put, url, _body, _headers, _opts ->
        assert String.match?(url, ~r"/events/#{Regex.escape(@instance_id)}(\?|$)")

        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => @instance_id})}}
      end)

      assert {:ok, _event} =
               CalendarAPI.update_event(integration, "primary", @instance_id, event_data)
    end

    test "patch_event_colour/4 addresses the instance verbatim", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :patch, url, _body, _headers, _opts ->
        assert String.match?(url, ~r"/events/#{Regex.escape(@instance_id)}(\?|$)")

        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => @instance_id})}}
      end)

      assert {:ok, _event} =
               CalendarAPI.patch_event_colour(integration, "primary", @instance_id, "tomato")
    end

    # The 404 the live calls actually answered. Asserting the shape here keeps
    # the fix honest: if the id is ever mangled again, the request goes to an
    # id Google does not know and this is what comes back.
    test "a genuinely missing instance still surfaces as :not_found", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert {:error, :not_found, "Event not found"} =
               CalendarAPI.delete_event(integration, "primary", @instance_id)
    end
  end

  describe "a UID we minted is still converted" do
    # The create path's whole purpose. `target_uid_for/2` yields
    # `tymeslot-mirror-<32 base32 chars>`; the hyphens put it outside base32hex,
    # so it must be hashed into an id Google will accept. A fix that exempted
    # every id with a non-base32hex character would break exactly this, and
    # every mirror placeholder with it.
    test "a mirror UID is hashed rather than passed through" do
      uid = "tymeslot-mirror-abc123def456abc123def456abc12345"

      result = EventMapper.uuid_to_google_event_id(uid)

      refute result == uid
      assert String.length(result) == 32
      # base32hex — the alphabet Google accepts, not the one the implementation
      # happens to emit. See the fallback's own comment.
      assert String.match?(result, ~r/^[a-v0-9]{5,1024}$/)
    end

    test "update_event/4 converts a mirror UID before addressing it", %{
      integration: integration
    } do
      uid = "tymeslot-mirror-abc123def456abc123def456abc12345"
      converted = EventMapper.uuid_to_google_event_id(uid)

      event_data = %{
        summary: "Busy",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600),
        timezone: "UTC"
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :put, url, _body, _headers, _opts ->
        assert String.match?(url, ~r"/events/#{Regex.escape(converted)}(\?|$)")
        refute String.contains?(url, "tymeslot-mirror")

        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => converted})}}
      end)

      assert {:ok, _event} = CalendarAPI.update_event(integration, "primary", uid, event_data)
    end

    test "delete_event/3 converts a mirror UID before addressing it", %{
      integration: integration
    } do
      uid = "tymeslot-mirror-abc123def456abc123def456abc12345"
      converted = EventMapper.uuid_to_google_event_id(uid)

      expect(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert String.match?(url, ~r"/events/#{Regex.escape(converted)}(\?|$)")

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = CalendarAPI.delete_event(integration, "primary", uid)
    end
  end

  describe "uuid_to_google_event_id/1 tells the two apart" do
    test "passes a Google instance id through unchanged" do
      assert EventMapper.uuid_to_google_event_id(@instance_id) == @instance_id
    end

    # Google mints an iCalUID as `{id}@google.com`, so the cached form of an
    # instance carries the suffix. Stripping it leaves the instance id, which
    # is what the write has to address.
    test "strips the @google.com suffix from a cached instance iCalUID" do
      assert EventMapper.uuid_to_google_event_id("#{@instance_id}@google.com") == @instance_id
    end

    # The shape is a whole-string match, not a "contains an underscore" one. A
    # UID that merely has an underscore is still arbitrary and still needs
    # hashing, or the exemption is a hole rather than a rule.
    test "does not exempt an arbitrary UID that merely contains an underscore" do
      uid = "some_random_uid_with_words"

      result = EventMapper.uuid_to_google_event_id(uid)

      refute result == uid
      assert String.match?(result, ~r/^[a-v0-9]{5,1024}$/)
    end

    test "does not exempt a stamp that is not a real instance stamp" do
      # Right punctuation, wrong digit counts — not a shape Google produces.
      uid = "abc123_2026904T14000Z"

      result = EventMapper.uuid_to_google_event_id(uid)

      refute result == uid
      assert String.match?(result, ~r/^[a-v0-9]{5,1024}$/)
    end
  end
end
