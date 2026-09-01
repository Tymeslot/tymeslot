defmodule Tymeslot.Infrastructure.Logging.MetadataRedactorTest do
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.Logging.MetadataRedactor

  # Most assertions exercise filter/2 directly: capture_log goes through the
  # default formatter, which only prints metadata keys whitelisted in its
  # `metadata:` list — so non-whitelisted keys (api_key, password, ...) are
  # invisible whether redacted or not. Testing the filter function directly
  # is what verifies the security guarantee.

  defp event(meta), do: %{level: :info, msg: {:string, "test"}, meta: meta}

  describe "filter/2" do
    test "redacts sensitive atom keys" do
      filtered =
        MetadataRedactor.filter(
          event(%{api_key: "sk-abc123", user_id: 42, password: "pw"}),
          []
        )

      assert filtered.meta.api_key == "[REDACTED]"
      assert filtered.meta.password == "[REDACTED]"
      assert filtered.meta.user_id == 42
    end

    test "matches sensitive substrings (refresh_token, set_cookie, x_authorization, ...)" do
      filtered =
        MetadataRedactor.filter(
          event(%{
            refresh_token: "rt-secret",
            set_cookie: "session=abc",
            x_authorization: "Bearer xyz",
            client_secret: "cs-secret",
            stripe_api_key: "sk-test",
            session_id: "session-token"
          }),
          []
        )

      assert filtered.meta.refresh_token == "[REDACTED]"
      assert filtered.meta.set_cookie == "[REDACTED]"
      assert filtered.meta.x_authorization == "[REDACTED]"
      assert filtered.meta.client_secret == "[REDACTED]"
      assert filtered.meta.stripe_api_key == "[REDACTED]"
      assert filtered.meta.session_id == "[REDACTED]"
    end

    test "matches case-insensitively and against string keys" do
      filtered =
        MetadataRedactor.filter(
          event(%{"API_KEY" => "leak", :Password => "leak2", :note => "kept"}),
          []
        )

      assert filtered.meta["API_KEY"] == "[REDACTED]"
      assert filtered.meta[:Password] == "[REDACTED]"
      assert filtered.meta[:note] == "kept"
    end

    test "redacts calendar identifiers but keeps the integration id" do
      filtered =
        MetadataRedactor.filter(
          event(%{
            calendar_id: "user@example.com",
            calendar_ids: ["a@example.com", "b@example.com"],
            calendar_path: "/calendars/user@example.com/work/",
            calendar_integration_id: 42
          }),
          []
        )

      assert filtered.meta.calendar_id == "[REDACTED]"
      assert filtered.meta.calendar_ids == "[REDACTED]"
      assert filtered.meta.calendar_path == "[REDACTED]"
      assert filtered.meta.calendar_integration_id == 42
    end

    test "redacts personal identifier keys but keeps pre-masked and non-address ones" do
      filtered =
        MetadataRedactor.filter(
          event(%{
            email: "alice@example.com",
            attendee_email: "bob@example.com",
            identifier: "carol@example.com",
            email_masked: "a***@example.com",
            identifier_masked: "c***@example.com",
            owner_email_masked: "d***@example.com",
            email_action: "reminder",
            provider_identifier: "evt_abc123"
          }),
          []
        )

      assert filtered.meta.email == "[REDACTED]"
      assert filtered.meta.attendee_email == "[REDACTED]"
      assert filtered.meta.identifier == "[REDACTED]"

      # `_masked` names a value the writer already masked, and the two keys
      # below carry no address at all — blanking either costs diagnostics for
      # no privacy gain.
      assert filtered.meta.email_masked == "a***@example.com"
      assert filtered.meta.identifier_masked == "c***@example.com"
      assert filtered.meta.owner_email_masked == "d***@example.com"
      assert filtered.meta.email_action == "reminder"
      assert filtered.meta.provider_identifier == "evt_abc123"
    end

    test "leaves non-sensitive metadata untouched" do
      filtered =
        MetadataRedactor.filter(
          event(%{
            user_id: 1,
            correlation_id: "abc",
            duration_ms: 12,
            event: :login_success
          }),
          []
        )

      assert filtered.meta == %{
               user_id: 1,
               correlation_id: "abc",
               duration_ms: 12,
               event: :login_success
             }
    end

    test "ignores events without a meta map" do
      ev = %{level: :info, msg: {:string, "no meta"}}
      assert MetadataRedactor.filter(ev, []) == ev
    end

    test "leaves non-atom non-string keys alone" do
      filtered = MetadataRedactor.filter(event(%{{:tagged, "k"} => "v"}), [])
      assert filtered.meta == %{{:tagged, "k"} => "v"}
    end
  end

  describe "attach/0" do
    test "is idempotent and survives repeated calls" do
      on_exit(fn -> :logger.remove_primary_filter(:tymeslot_metadata_redactor) end)

      assert :ok = MetadataRedactor.attach()
      assert :ok = MetadataRedactor.attach()

      filter_ids = :logger.get_primary_config() |> Map.fetch!(:filters) |> Keyword.keys()
      assert :tymeslot_metadata_redactor in filter_ids
    end
  end
end
