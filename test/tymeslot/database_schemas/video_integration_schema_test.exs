defmodule Tymeslot.DatabaseSchemas.VideoIntegrationSchemaTest do
  use Tymeslot.DataCase, async: true
  import ExUnit.CaptureLog

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema

  describe "changeset/2 - provider validation" do
    test "accepts valid providers (mirotalk, google_meet, custom)" do
      user = insert(:user)

      # Mirotalk
      attrs = %{
        user_id: user.id,
        name: "My MiroTalk",
        provider: "mirotalk",
        base_url: "https://mirotalk.example.com",
        api_key: "test-key"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      assert changeset.valid?

      # Google Meet
      attrs = %{
        user_id: user.id,
        name: "My Google Meet",
        provider: "google_meet",
        access_token: "test-token",
        refresh_token: "test-refresh"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      assert changeset.valid?

      # Custom
      attrs = %{
        user_id: user.id,
        name: "My Custom",
        provider: "custom",
        custom_meeting_url: "https://custom.example.com"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      assert changeset.valid?
    end

    test "rejects invalid providers" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "Invalid Provider",
        provider: "invalid_provider"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).provider
    end
  end

  describe "changeset/2 - required fields" do
    test "requires name" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        provider: "mirotalk",
        base_url: "https://example.com",
        api_key: "test-key"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "requires user_id" do
      attrs = %{
        name: "My Integration",
        provider: "mirotalk",
        base_url: "https://example.com",
        api_key: "test-key"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
    end
  end

  describe "changeset/2 - mirotalk provider specific fields" do
    test "requires base_url for mirotalk" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "MiroTalk",
        provider: "mirotalk",
        api_key: "test-key"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).base_url
    end

    test "requires api_key for mirotalk" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "MiroTalk",
        provider: "mirotalk",
        base_url: "https://mirotalk.example.com"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).api_key
    end

    test "validates base_url is a valid URL for mirotalk" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "MiroTalk",
        provider: "mirotalk",
        base_url: "not-a-valid-url",
        api_key: "test-key"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      refute changeset.valid?
      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).base_url
    end
  end

  describe "changeset/2 - google_meet provider specific fields" do
    test "requires access_token for google_meet" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "Google Meet",
        provider: "google_meet",
        refresh_token: "test-refresh"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).access_token
    end

    test "requires refresh_token for google_meet" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "Google Meet",
        provider: "google_meet",
        access_token: "test-token"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).refresh_token
    end
  end

  describe "changeset/2 - custom provider specific fields" do
    test "requires custom_meeting_url for custom provider" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "Custom",
        provider: "custom"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).custom_meeting_url
    end

    test "validates custom_meeting_url is a valid URL" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "Custom",
        provider: "custom",
        custom_meeting_url: "not-a-valid-url"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      refute changeset.valid?
      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).custom_meeting_url
    end
  end

  describe "changeset/2 - credential encryption" do
    test "encrypts api_key before storage" do
      user = insert(:user)
      api_key = "secret-api-key-123"

      attrs = %{
        user_id: user.id,
        name: "MiroTalk",
        provider: "mirotalk",
        base_url: "https://mirotalk.example.com",
        api_key: api_key
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      assert changeset.valid?

      # Virtual field should be removed
      refute Map.has_key?(changeset.changes, :api_key)

      # Encrypted field should exist and be different from plain text
      assert Map.has_key?(changeset.changes, :api_key_encrypted)
      assert changeset.changes.api_key_encrypted != api_key
      assert is_binary(changeset.changes.api_key_encrypted)
    end

    test "encrypts access_token before storage" do
      user = insert(:user)
      access_token = "secret-access-token-123"

      attrs = %{
        user_id: user.id,
        name: "Google Meet",
        provider: "google_meet",
        access_token: access_token,
        refresh_token: "refresh-token"
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      assert changeset.valid?

      # Virtual field should be removed
      refute Map.has_key?(changeset.changes, :access_token)

      # Encrypted field should exist
      assert Map.has_key?(changeset.changes, :access_token_encrypted)
      assert changeset.changes.access_token_encrypted != access_token
      assert is_binary(changeset.changes.access_token_encrypted)
    end

    test "encrypts refresh_token before storage" do
      user = insert(:user)
      refresh_token = "secret-refresh-token-123"

      attrs = %{
        user_id: user.id,
        name: "Google Meet",
        provider: "google_meet",
        access_token: "access-token",
        refresh_token: refresh_token
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      assert changeset.valid?

      refute Map.has_key?(changeset.changes, :refresh_token)
      assert Map.has_key?(changeset.changes, :refresh_token_encrypted)
      assert changeset.changes.refresh_token_encrypted != refresh_token
    end

    test "handles nil credentials gracefully" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "Custom",
        provider: "custom",
        custom_meeting_url: "https://custom.example.com",
        api_key: nil,
        access_token: nil
      }

      changeset = VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, attrs)
      assert changeset.valid?

      # Nil values should not create encrypted fields
      refute Map.has_key?(changeset.changes, :api_key_encrypted)
      refute Map.has_key?(changeset.changes, :access_token_encrypted)
    end
  end

  describe "decrypt_credentials/1" do
    test "decrypts all credential fields" do
      user = insert(:user)

      # Create integration with encrypted credentials
      {:ok, integration} =
        %VideoIntegrationSchema{}
        |> VideoIntegrationSchema.changeset(%{
          user_id: user.id,
          name: "Google Meet",
          provider: "google_meet",
          access_token: "secret-access",
          refresh_token: "secret-refresh"
        })
        |> Repo.insert()

      # Decrypt credentials
      decrypted = VideoIntegrationSchema.decrypt_credentials(integration)

      # Virtual fields should now contain decrypted values
      assert decrypted.access_token == "secret-access"
      assert decrypted.refresh_token == "secret-refresh"
    end

    test "handles nil encrypted fields gracefully" do
      user = insert(:user)

      {:ok, integration} =
        %VideoIntegrationSchema{}
        |> VideoIntegrationSchema.changeset(%{
          user_id: user.id,
          name: "Custom",
          provider: "custom",
          custom_meeting_url: "https://custom.example.com"
        })
        |> Repo.insert()

      # Decrypt credentials (all should be nil)
      decrypted = VideoIntegrationSchema.decrypt_credentials(integration)

      assert decrypted.api_key == nil
      assert decrypted.access_token == nil
      assert decrypted.refresh_token == nil
    end

    test "handles decryption failure gracefully and logs error" do
      user = insert(:user)

      # Create integration with manually corrupted encrypted binary
      corrupted_binary =
        <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
          21, 22, 23, 24, 25, 26, 27, 28, 29, 30>>

      integration =
        insert(:video_integration,
          user: user,
          api_key_encrypted: corrupted_binary
        )

      # Decrypt should not crash, should return nil for failed field, and should log error
      logs =
        capture_log(fn ->
          decrypted = VideoIntegrationSchema.decrypt_credentials(integration)
          assert decrypted.api_key == nil
        end)

      assert logs =~ "Failed to decrypt api_key for video integration"
    end
  end

  describe "set_as_default_changeset/1" do
    test "sets is_default to true" do
      integration = %VideoIntegrationSchema{is_default: false}

      changeset = VideoIntegrationSchema.set_as_default_changeset(integration)

      assert changeset.changes.is_default == true
    end
  end

  describe "changeset/2 - foreign key constraints" do
    test "enforces foreign key constraint on user_id" do
      attrs = %{
        user_id: 999_999,
        name: "Integration",
        provider: "custom",
        custom_meeting_url: "https://custom.example.com"
      }

      {:error, changeset} =
        %VideoIntegrationSchema{}
        |> VideoIntegrationSchema.changeset(attrs)
        |> Repo.insert()

      assert "does not exist" in errors_on(changeset).user_id
    end
  end
end
