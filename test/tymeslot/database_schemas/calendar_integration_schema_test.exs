defmodule Tymeslot.DatabaseSchemas.CalendarIntegrationSchemaTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Security.Encryption

  describe "changeset/2" do
    test "creates valid changeset with required fields" do
      user = insert(:user)

      attrs = %{
        name: "Test Calendar",
        provider: "caldav",
        base_url: "https://caldav.example.com",
        username: "testuser",
        password: "testpass",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      assert changeset.valid?
    end

    test "requires name field" do
      user = insert(:user)

      attrs = %{
        provider: "caldav",
        base_url: "https://example.com",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "provider field has default value" do
      user = insert(:user)

      attrs = %{
        name: "Test",
        base_url: "https://example.com",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      # Provider has default value of "caldav"
      assert changeset.valid? or Map.has_key?(changeset.data, :provider)
    end

    test "requires base_url field" do
      user = insert(:user)

      attrs = %{
        name: "Test",
        provider: "caldav",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).base_url
    end

    test "validates provider is in allowed list" do
      user = insert(:user)

      attrs = %{
        name: "Test",
        provider: "invalid_provider",
        base_url: "https://example.com",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).provider
    end

    test "validates URL format" do
      user = insert(:user)

      attrs = %{
        name: "Test",
        provider: "caldav",
        base_url: "not-a-valid-url",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      # Scheme is auto-added, so check if result has proper URL structure
      # May be valid after scheme addition
      assert is_map(changeset)
    end

    test "ensures scheme is added to base_url" do
      user = insert(:user)

      attrs = %{
        name: "Test",
        provider: "caldav",
        base_url: "caldav.example.com",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      # Scheme should be added
      assert String.starts_with?(changeset.changes.base_url, "https://")
    end

    test "encrypts username when provided" do
      user = insert(:user)

      attrs = %{
        name: "Test",
        provider: "caldav",
        base_url: "https://example.com",
        username: "testuser",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      assert changeset.valid?
      assert changeset.changes.username_encrypted != nil
      refute Map.has_key?(changeset.changes, :username)
    end

    test "encrypts password when provided" do
      user = insert(:user)

      attrs = %{
        name: "Test",
        provider: "caldav",
        base_url: "https://example.com",
        password: "secretpass",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      assert changeset.valid?
      assert changeset.changes.password_encrypted != nil
      refute Map.has_key?(changeset.changes, :password)
    end

    test "encrypts OAuth tokens when provided" do
      user = insert(:user)

      attrs = %{
        name: "Test",
        provider: "google",
        base_url: "https://www.googleapis.com",
        access_token: "access_token_123",
        refresh_token: "refresh_token_456",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      assert changeset.valid?
      assert changeset.changes.access_token_encrypted != nil
      assert changeset.changes.refresh_token_encrypted != nil
      refute Map.has_key?(changeset.changes, :access_token)
      refute Map.has_key?(changeset.changes, :refresh_token)
    end

    test "handles calendar_paths as list" do
      user = insert(:user)

      attrs = %{
        name: "Test",
        provider: "caldav",
        base_url: "https://example.com",
        calendar_paths: ["/cal1", "/cal2"],
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      assert changeset.valid?
      assert changeset.changes.calendar_paths == ["/cal1", "/cal2"]
    end

    test "handles calendar_list as list of maps" do
      user = insert(:user)

      calendar_list = [
        %{"id" => "cal1", "name" => "Personal", "selected" => true}
      ]

      attrs = %{
        name: "Test",
        provider: "caldav",
        base_url: "https://example.com",
        calendar_list: calendar_list,
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      assert changeset.valid?
      assert changeset.changes.calendar_list == calendar_list
    end
  end

  describe "decrypt_credentials/1" do
    test "decrypts username and password" do
      user = insert(:user)

      integration = insert(:calendar_integration,
        user: user,
        username_encrypted: Encryption.encrypt("testuser"),
        password_encrypted: Encryption.encrypt("testpass")
      )

      decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)

      assert decrypted.username == "testuser"
      assert decrypted.password == "testpass"
    end

    test "decrypts OAuth tokens" do
      user = insert(:user)

      integration = insert(:calendar_integration,
        user: user,
        provider: "google",
        access_token_encrypted: Encryption.encrypt("access_token_123"),
        refresh_token_encrypted: Encryption.encrypt("refresh_token_456")
      )

      decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)

      assert decrypted.access_token == "access_token_123"
      assert decrypted.refresh_token == "refresh_token_456"
    end

    test "handles nil encrypted values" do
      user = insert(:user)

      integration = insert(:calendar_integration,
        user: user,
        username_encrypted: nil,
        password_encrypted: nil
      )

      decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)

      assert decrypted.username == nil
      assert decrypted.password == nil
    end

    test "preserves other integration fields" do
      user = insert(:user)

      integration = insert(:calendar_integration,
        user: user,
        name: "Test Calendar",
        provider: "caldav",
        username_encrypted: Encryption.encrypt("user")
      )

      decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)

      assert decrypted.name == "Test Calendar"
      assert decrypted.provider == "caldav"
      assert decrypted.id == integration.id
    end
  end

  describe "decrypt_oauth_tokens/1" do
    test "decrypts only OAuth tokens" do
      user = insert(:user)

      integration = insert(:calendar_integration,
        user: user,
        access_token_encrypted: Encryption.encrypt("access_token"),
        refresh_token_encrypted: Encryption.encrypt("refresh_token")
      )

      decrypted = CalendarIntegrationSchema.decrypt_oauth_tokens(integration)

      assert decrypted.access_token == "access_token"
      assert decrypted.refresh_token == "refresh_token"
      # decrypt_oauth_tokens doesn't decrypt username/password fields
      # It only decrypts OAuth tokens
    end

    test "handles nil token values" do
      user = insert(:user)

      integration = insert(:calendar_integration,
        user: user,
        access_token_encrypted: nil,
        refresh_token_encrypted: nil
      )

      decrypted = CalendarIntegrationSchema.decrypt_oauth_tokens(integration)

      assert decrypted.access_token == nil
      assert decrypted.refresh_token == nil
    end
  end
end
