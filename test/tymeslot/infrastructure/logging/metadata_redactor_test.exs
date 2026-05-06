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
