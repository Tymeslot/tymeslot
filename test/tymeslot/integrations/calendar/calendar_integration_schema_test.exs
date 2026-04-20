defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationSchemaTest do
  use Tymeslot.DataCase, async: true
  @moduletag :database
  @moduletag :schema

  import Ecto.Changeset
  import Tymeslot.Factory
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
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

      assert changeset.valid?
      assert get_field(changeset, :provider) == "caldav"
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

      # ensure_scheme prepends https:// so "not-a-valid-url" becomes a valid URL
      assert changeset.valid?
      assert changeset.changes.base_url == "https://not-a-valid-url"
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

    # Regression for Tymeslot#45: a previous Nextcloud-specific regex clobbered
    # hostnames containing "cloud", "nextcloud", or "owncloud", so integrations
    # at https://cloud.example.com were stored as "https:/" and then rejected
    # by the URL validator with a misleading "Must be a valid HTTP or HTTPS
    # URL" message at submit time.
    test "accepts Nextcloud-style subdomains as base_url" do
      user = insert(:user)

      for host <- ~w(cloud.example.com nextcloud.example.com owncloud.example.com) do
        attrs = %{
          name: "Test",
          provider: "nextcloud",
          base_url: "https://#{host}",
          user_id: user.id
        }

        changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

        assert changeset.valid?,
               "expected valid changeset for #{host}, got: #{inspect(changeset.errors)}"

        assert get_field(changeset, :base_url) == "https://#{host}"
      end
    end

    test "strips browser-pasted path suffixes from base_url" do
      user = insert(:user)

      attrs = %{
        name: "Test",
        provider: "nextcloud",
        base_url: "https://cloud.example.com/apps/calendar/dayGridMonth/2026-04-20",
        user_id: user.id
      }

      changeset = CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, attrs)

      assert changeset.valid?
      assert get_field(changeset, :base_url) == "https://cloud.example.com"
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

  describe "unique_active_calendar_account_per_user constraint" do
    test "allows same provider with different account IDs" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        provider_account_id: "https://dav.example.com||user1"
      )

      attrs = %{
        name: "Second CalDAV",
        provider: "caldav",
        base_url: "https://dav.example.com",
        provider_account_id: "https://dav.example.com||user2",
        user_id: user.id
      }

      assert {:ok, _integration} =
               %CalendarIntegrationSchema{}
               |> CalendarIntegrationSchema.changeset(attrs)
               |> Repo.insert()
    end

    test "rejects same provider with same account ID" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        provider_account_id: "https://dav.example.com||user1"
      )

      attrs = %{
        name: "Duplicate CalDAV",
        provider: "caldav",
        base_url: "https://dav.example.com",
        provider_account_id: "https://dav.example.com||user1",
        user_id: user.id
      }

      {:error, changeset} =
        %CalendarIntegrationSchema{}
        |> CalendarIntegrationSchema.changeset(attrs)
        |> Repo.insert()

      assert "an integration for this account already exists" in errors_on(changeset).user_id
    end
  end

  describe "decrypt_credentials/1" do
    test "decrypts username and password" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
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

      integration =
        insert(:calendar_integration,
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

      integration =
        insert(:calendar_integration,
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

      integration =
        insert(:calendar_integration,
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

      integration =
        insert(:calendar_integration,
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

      integration =
        insert(:calendar_integration,
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
