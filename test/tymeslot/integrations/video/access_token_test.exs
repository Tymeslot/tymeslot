defmodule Tymeslot.Integrations.Video.AccessTokenTest do
  @moduledoc """
  `Video.access_token/2` exists so that callers outside this domain never have
  to decrypt an integration's credentials or drive an OAuth refresh themselves.
  Both shortcuts are worse than verbose: decrypting elsewhere spreads knowledge
  of which fields are encrypted, and refreshing through a bare OAuth helper
  skips the lock that stops two callers spending the same refresh token, and
  skips the write-back that makes the result useful to anyone else.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :video

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Security.Encryption

  defp google_meet_integration(user, attrs) do
    insert(
      :video_integration,
      Keyword.merge(
        [
          user: user,
          provider: "google_meet",
          is_active: true,
          oauth_scope: "https://www.googleapis.com/auth/meetings.space.created"
        ],
        attrs
      )
    )
  end

  setup do
    %{user: insert(:user)}
  end

  describe "access_token/2" do
    test "returns the stored token without refreshing while it is still valid", %{user: user} do
      integration =
        google_meet_integration(user,
          access_token_encrypted: Encryption.encrypt("still-good"),
          refresh_token_encrypted: Encryption.encrypt("refresh-me"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      assert {:ok, "still-good"} = Video.access_token(integration.id, user.id)
    end

    test "refreshes through the provider's own token path and persists the result",
         %{user: user} do
      # The injection point is the one Core's provider uses. A caller that
      # refreshed through `GoogleOAuthHelper` directly would bypass this, and
      # would also bypass the lock and the write-back asserted below.
      with_config(:tymeslot, :google_calendar_oauth_helper, __MODULE__.StubOAuthHelper)

      integration =
        google_meet_integration(user,
          access_token_encrypted: Encryption.encrypt("expired"),
          refresh_token_encrypted: Encryption.encrypt("refresh-me"),
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      assert {:ok, "freshly-minted"} = Video.access_token(integration.id, user.id)

      # Persisted, so the next caller does not spend the refresh token again.
      {:ok, reloaded} = VideoIntegrationQueries.get_for_user(integration.id, user.id)
      assert Encryption.decrypt(reloaded.access_token_encrypted) == "freshly-minted"
    end

    test "refuses a provider that holds no OAuth grant", %{user: user} do
      integration = insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

      assert {:error, :unsupported_provider} = Video.access_token(integration.id, user.id)
    end

    test "refuses an integration belonging to another user", %{user: user} do
      other = insert(:user)
      integration = google_meet_integration(other, [])

      assert {:error, :not_found} = Video.access_token(integration.id, user.id)
    end
  end

  defmodule StubOAuthHelper do
    @moduledoc false

    @spec refresh_access_token(String.t(), String.t() | nil) :: {:ok, map()}
    def refresh_access_token(_refresh_token, _scope) do
      {:ok,
       %{
         access_token: "freshly-minted",
         refresh_token: "refresh-me",
         expires_in: 3600,
         expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
         scope: "https://www.googleapis.com/auth/meetings.space.created"
       }}
    end
  end
end
