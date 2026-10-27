defmodule Tymeslot.Integrations.Calendar.TokensTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp integration(attrs) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [
          user: insert(:user),
          provider: "google",
          access_token_encrypted: Encryption.encrypt("old-access"),
          refresh_token_encrypted: Encryption.encrypt("old-refresh")
        ],
        attrs
      )
    )
  end

  defp refreshed(access \\ "new-access"), do: {:ok, {access, "new-refresh", in_seconds(3600)}}

  describe "with_access_token/4" do
    test "uses the stored token without refreshing while it is valid" do
      integration = integration(token_expires_at: in_seconds(3600))

      assert {:ok, "old-access"} =
               Tokens.with_access_token(
                 integration,
                 fn _integration -> flunk("refreshed") end,
                 &{:ok, &1}
               )
    end

    test "refreshes a token inside the buffer, persists it, and calls back with the new one" do
      integration = integration(token_expires_at: in_seconds(120))

      assert {:ok, "new-access"} =
               Tokens.with_access_token(
                 integration,
                 fn _integration -> refreshed() end,
                 &{:ok, &1}
               )

      stored =
        CalendarIntegrationSchema.decrypt_oauth_tokens(
          Repo.get!(CalendarIntegrationSchema, integration.id)
        )

      assert {stored.access_token, stored.refresh_token} == {"new-access", "new-refresh"}
    end

    test "refreshes a token whose expiry was never recorded" do
      integration = integration(token_expires_at: nil)

      assert {:ok, "new-access"} =
               Tokens.with_access_token(
                 integration,
                 fn _integration -> refreshed() end,
                 &{:ok, &1}
               )
    end

    test "returns a provider's refresh failure as it is, without calling back" do
      integration = integration(token_expires_at: in_seconds(-60))
      failure = {:error, :unauthorized, "Token refresh failed: invalid_grant"}

      assert ^failure =
               Tokens.with_access_token(integration, fn _integration -> failure end, fn _token ->
                 flunk("called back without a token")
               end)
    end

    # The row would still hold the old token, so every later caller would
    # refresh again; with Google's one-use refresh tokens that risks revocation.
    test "surfaces a refresh that could not be written" do
      integration = integration(token_expires_at: in_seconds(-60))
      unwritable = {:ok, {"new-access", "new-refresh", "not a timestamp"}}

      assert {:error, :token_persist_failed} =
               Tokens.with_access_token(
                 integration,
                 fn _integration -> unwritable end,
                 &{:ok, &1}
               )
    end

    test "answers not found for an integration deleted before the refresh" do
      integration = integration(token_expires_at: in_seconds(-60))
      Repo.delete!(integration)

      assert {:error, :integration_not_found} =
               Tokens.with_access_token(
                 integration,
                 fn _integration -> flunk("refreshed") end,
                 &{:ok, &1}
               )
    end
  end

  describe "refresh_oauth_token/2" do
    test "refreshes a Google integration through its API module" do
      integration = integration(token_expires_at: in_seconds(-60))

      expect(GoogleCalendarAPIMock, :refresh_token, fn %{id: id} when id == integration.id ->
        refreshed()
      end)

      assert {:ok, %{access_token: "new-access", refresh_token: "new-refresh"}} =
               Tokens.refresh_oauth_token(integration)
    end

    test "refreshes an Outlook integration through its API module" do
      integration = integration(provider: "outlook", token_expires_at: in_seconds(-60))

      expect(OutlookCalendarAPIMock, :refresh_token, fn _integration -> refreshed("outlook") end)

      assert {:ok, %{access_token: "outlook"}} = Tokens.refresh_oauth_token(integration)
    end

    test "leaves a token valid beyond the buffer alone" do
      integration = integration(token_expires_at: in_seconds(3600))

      assert {:ok, %{access_token: "old-access"}} = Tokens.refresh_oauth_token(integration)
    end

    test "refreshes ahead of expiry within a wider buffer" do
      integration = integration(token_expires_at: in_seconds(3600))
      expect(GoogleCalendarAPIMock, :refresh_token, fn _integration -> refreshed() end)

      assert {:ok, %{access_token: "new-access"}} =
               Tokens.refresh_oauth_token(integration, buffer_seconds: 7200)
    end

    # The caller (the refresh job) read the row before an API call refreshed
    # it. A Google token lives an hour, inside the job's two-hour buffer, so
    # the buffer alone would refresh it again.
    test "does not refresh again a token someone refreshed since the caller read it" do
      seen = integration(token_expires_at: in_seconds(600))

      seen
      |> Changeset.change(token_expires_at: DateTime.truncate(in_seconds(3600), :second))
      |> Repo.update!()

      assert {:ok, %{token_expires_at: expires_at}} =
               Tokens.refresh_oauth_token(seen, buffer_seconds: 7200)

      assert DateTime.compare(expires_at, seen.token_expires_at) == :gt
    end

    test "clears a stale sync error on success" do
      integration =
        integration(sync_error: "Token refresh failed", token_expires_at: in_seconds(-60))

      expect(GoogleCalendarAPIMock, :refresh_token, fn _integration -> refreshed() end)

      assert {:ok, %{sync_error: nil}} = Tokens.refresh_oauth_token(integration)
      assert Repo.get!(CalendarIntegrationSchema, integration.id).sync_error == nil
    end

    test "keeps the reason an integration flagged for reconnection carries" do
      integration =
        integration(
          sync_error: "Booking calendar deleted",
          needs_reauth: true,
          token_expires_at: in_seconds(-60)
        )

      expect(GoogleCalendarAPIMock, :refresh_token, fn _integration -> refreshed() end)

      assert {:ok, _integration} = Tokens.refresh_oauth_token(integration)

      assert Repo.get!(CalendarIntegrationSchema, integration.id).sync_error ==
               "Booking calendar deleted"
    end

    test "reports a provider's typed failure as a pair" do
      integration = integration(provider: "outlook", token_expires_at: in_seconds(-60))

      expect(OutlookCalendarAPIMock, :refresh_token, fn _integration ->
        {:error, :authentication_error, "Microsoft Client ID not configured"}
      end)

      assert {:error, {:authentication_error, "Microsoft Client ID not configured"}} =
               Tokens.refresh_oauth_token(integration)
    end

    test "refuses a provider without OAuth" do
      assert {:error, :unsupported_provider} =
               Tokens.refresh_oauth_token(integration(provider: "caldav"))
    end

    test "flags an integration whose stored credentials stopped decrypting" do
      integration = integration(token_expires_at: in_seconds(-60))

      # The caller holds a copy it read while the row still decrypted; the row
      # stops decrypting before the re-read under the refresh lock.
      held = CalendarIntegrationSchema.decrypt_credentials(integration)

      integration
      |> Changeset.change(refresh_token_encrypted: :crypto.strong_rand_bytes(40))
      |> Repo.update!()

      assert {:error, :requires_reencryption} = Tokens.refresh_oauth_token(held)
      assert Repo.get!(CalendarIntegrationSchema, integration.id).needs_reauth
    end
  end
end
