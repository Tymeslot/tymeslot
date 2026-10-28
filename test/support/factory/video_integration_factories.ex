defmodule Tymeslot.Factory.VideoIntegrationFactories do
  @moduledoc """
  The video integration factories, mixed into `Tymeslot.Factory` with
  `use` (ExMachina's way of splitting a factory across files). Call them
  through `Tymeslot.Factory`: `insert(:zoom_video_integration, user: user)`.
  """

  defmacro __using__(_opts) do
    quote do
      alias Tymeslot.Integrations.Video.VideoIntegrationSchema
      alias Tymeslot.Security.Encryption

      @spec video_integration_factory() :: VideoIntegrationSchema.t()
      def video_integration_factory do
        api_key = sequence(:api_key, &"api_key_#{&1}")

        %VideoIntegrationSchema{
          name: sequence(:video_name, &"Video #{&1}"),
          provider: "mirotalk",
          base_url: "https://video.example.com",
          api_key_encrypted: Encryption.encrypt(api_key),
          tenant_id_encrypted: Encryption.encrypt("test-tenant-id"),
          client_id_encrypted: Encryption.encrypt("test-client-id"),
          client_secret_encrypted: Encryption.encrypt("test-client-secret"),
          teams_user_id_encrypted: Encryption.encrypt("test-teams-user-id"),
          access_token_encrypted: Encryption.encrypt("test-access-token"),
          refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
          provider_account_id: sequence(:video_account_id, &"video-account-#{&1}"),
          is_active: true,
          settings: %{},
          user: build(:user)
        }
      end

      @doc """
      A connected Zoom integration: OAuth tokens valid for the next hour and
      all three meeting scopes, with none of the API-key or Teams credentials.
      """
      @spec zoom_video_integration_factory() :: VideoIntegrationSchema.t()
      def zoom_video_integration_factory do
        struct!(video_integration_factory(),
          name: "Zoom",
          provider: "zoom",
          base_url: nil,
          api_key_encrypted: nil,
          tenant_id_encrypted: nil,
          client_id_encrypted: nil,
          client_secret_encrypted: nil,
          teams_user_id_encrypted: nil,
          access_token_encrypted: Encryption.encrypt("access-token"),
          refresh_token_encrypted: Encryption.encrypt("refresh-token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "meeting:write:meeting meeting:update:meeting meeting:delete:meeting",
          provider_account_id: nil
        )
      end

      @doc """
      A Nextcloud Talk integration on `https://cloud.example.com`, signed in
      as `organiser` with the app password `Abcde-Fghij-Klmno-Pqrst-Uvwxy`.

      Takes `:login` and `:app_password` in plain text and encrypts them; the
      account id (`"<base_url>||<login>"`) follows `:base_url` and `:login`,
      so a different server or login is a different account.
      """
      @spec talk_video_integration_factory(map()) :: VideoIntegrationSchema.t()
      def talk_video_integration_factory(attrs) do
        {login, attrs} = Map.pop(attrs, :login, "organiser")
        {app_password, attrs} = Map.pop(attrs, :app_password, "Abcde-Fghij-Klmno-Pqrst-Uvwxy")
        base_url = Map.get(attrs, :base_url, "https://cloud.example.com")

        video_integration_factory()
        |> struct!(
          name: "Nextcloud Talk",
          provider: "nextcloud_talk",
          base_url: base_url,
          api_key_encrypted: nil,
          tenant_id_encrypted: nil,
          teams_user_id_encrypted: nil,
          access_token_encrypted: nil,
          refresh_token_encrypted: nil,
          client_id_encrypted: Encryption.encrypt(login),
          client_secret_encrypted: Encryption.encrypt(app_password),
          provider_account_id: base_url <> "||" <> login
        )
        |> merge_attributes(attrs)
        |> evaluate_lazy_attributes()
      end
    end
  end
end
