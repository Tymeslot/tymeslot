defmodule Tymeslot.EmailSending.SenderResolverTest do
  @moduledoc "Verifies booking owner resolution and the exact-version credential boundary."

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.Sender
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.Security.Encryption

  setup do
    with_config(:tymeslot,
      user_smtp_enabled: true,
      email: [from_name: "Platform bookings", from_email: "bookings@platform.example"]
    )

    %{owner: insert(:user)}
  end

  describe "resolve_booking_sender/1" do
    test "feature-off legacy resources and configured users use the platform", %{owner: owner} do
      settings(owner)
      with_config(:tymeslot, user_smtp_enabled: false)

      assert {:ok, %Sender{kind: :platform, owner_id: nil}} =
               EmailSending.resolve_booking_sender(%{attendee_email: "guest@example.com"})

      assert {:ok, sender} = EmailSending.resolve_booking_sender(resource(owner))
      assert sender == Sender.platform(owner.id)
      assert sender.from_address == "bookings@platform.example"
    end

    test "rejects unsupported resources and absent or invalid owners before querying" do
      for invalid <- [nil, [], "booking", 1] do
        assert {:error, :invalid_sender} = EmailSending.resolve_booking_sender(invalid)
      end

      for invalid <- [nil, 0, -1, "1", 1.0, 9_223_372_036_854_775_808] do
        assert {:error, :owner_not_found} =
                 EmailSending.resolve_booking_sender(%{organizer_user_id: invalid})
      end
    end

    test "a deleted owner cannot resolve an old resource", %{owner: owner} do
      settings(owner)
      booking = resource(owner)
      Repo.delete!(owner)

      assert {:error, :owner_not_found} = EmailSending.resolve_booking_sender(booking)
    end

    test "missing and disabled settings choose the owner's platform identity", %{owner: owner} do
      assert {:ok, sender} = EmailSending.resolve_booking_sender(resource(owner))
      assert sender == Sender.platform(owner.id)

      settings(owner, %{enabled: false})

      assert {:ok, ^sender} = EmailSending.resolve_booking_sender(resource(owner))
    end

    test "the organizer's settings win over recipient and user fields", %{owner: owner} do
      organizer_settings = settings(owner)
      recipient = insert(:user)
      settings(recipient, %{from_name: "Recipient", from_address: "recipient@other.example"})

      booking =
        Map.merge(resource(owner), %{
          attendee_email: recipient.email,
          attendee_user_id: recipient.id,
          user_id: recipient.id,
          recipient: recipient.email
        })

      assert {:ok, sender} = EmailSending.resolve_booking_sender(booking)
      assert sender == Sender.from_settings(organizer_settings)
    end

    test "rejects foreign, malformed and unsupported attached contexts", %{owner: owner} do
      foreign = insert(:user)
      foreign_sender = foreign |> settings() |> Sender.from_settings()

      for context <- [
            foreign_sender,
            Sender.platform(foreign.id),
            %{foreign_sender | owner_id: owner.id, kind: :unknown},
            %{owner_id: owner.id, kind: :platform},
            "sender"
          ] do
        assert {:error, :invalid_sender} =
                 EmailSending.resolve_booking_sender(
                   Map.put(resource(owner), :email_sender, context)
                 )
      end
    end

    test "resolved senders expose identity and version without transport credentials", %{
      owner: owner
    } do
      stored = settings(owner)

      assert {:ok, sender} = EmailSending.resolve_booking_sender(resource(owner))
      assert sender == Sender.from_settings(stored)

      for secret_field <- [
            :host,
            :port,
            :security,
            :username,
            :password,
            :username_encrypted,
            :password_encrypted
          ] do
        refute Map.has_key?(sender, secret_field)
      end

      refute inspect(sender) =~ "smtp-login-secret"
      refute inspect(sender) =~ "smtp-password-secret"
    end

    test "an attached platform sender stays frozen after SMTP is enabled", %{owner: owner} do
      booking = resource(owner)
      assert {:ok, platform} = EmailSending.resolve_booking_sender(booking)
      stored = settings(owner)

      with_config(:tymeslot,
        email: [from_name: "Changed platform", from_email: "changed@platform.example"]
      )

      assert {:ok, ^platform} =
               EmailSending.resolve_booking_sender(Map.put(booking, :email_sender, platform))

      assert platform.from_address == "bookings@platform.example"
      assert {:ok, current} = EmailSending.resolve_booking_sender(booking)
      assert current == Sender.from_settings(stored)
    end
  end

  describe "delivery_credentials/1" do
    test "loads only the selected current version's decrypted transport fields", %{owner: owner} do
      settings(owner)
      assert {:ok, sender} = EmailSending.resolve_booking_sender(resource(owner))

      assert {:ok,
              %{
                host: "smtp.customer.example",
                port: 587,
                security: :starttls,
                username: "smtp-login-secret",
                password: "smtp-password-secret"
              }} == EmailSending.delivery_credentials(sender)
    end

    test "rejects invalid contexts and versions without a database exception", %{owner: owner} do
      sender = owner |> settings() |> Sender.from_settings()

      invalid_senders = [
        nil,
        %{},
        Sender.platform(owner.id),
        %{sender | kind: :unknown}
      ]

      for invalid <- invalid_senders do
        assert {:error, :invalid_sender} = EmailSending.delivery_credentials(invalid)
      end

      for field <- [:owner_id, :settings_id, :revision], value <- [nil, 0, -1, "1", 1.0] do
        assert {:error, :invalid_sender} =
                 EmailSending.delivery_credentials(Map.put(sender, field, value))
      end

      assert {:error, :invalid_sender} =
               EmailSending.delivery_credentials(%{sender | revision: 2_147_483_647})

      assert {:error, :invalid_sender} =
               EmailSending.delivery_credentials(%{sender | owner_id: 9_223_372_036_854_775_808})
    end

    test "requires the same owner, settings row, revision and From identity", %{owner: owner} do
      sender = owner |> settings() |> Sender.from_settings()
      foreign = insert(:user)
      foreign_settings = settings(foreign)

      for modified <- [
            %{sender | owner_id: foreign.id},
            %{sender | settings_id: foreign_settings.id},
            %{sender | revision: sender.revision + 1},
            %{sender | from_name: "Another identity"},
            %{sender | from_address: "another@customer.example"}
          ] do
        assert {:error, :settings_changed} = EmailSending.delivery_credentials(modified)
      end
    end

    test "a frozen custom sender cannot load credentials from an edited configuration", %{
      owner: owner
    } do
      original = settings(owner)
      booking = resource(owner)
      assert {:ok, sender} = EmailSending.resolve_booking_sender(booking)

      updated =
        original
        |> Changeset.change(
          revision: 2,
          tested_revision: 2,
          tested_at: DateTime.utc_now(),
          host: "smtp.changed.example",
          username_encrypted: Encryption.encrypt("updated-login"),
          password_encrypted: Encryption.encrypt("updated-password"),
          from_address: "updated@customer.example"
        )
        |> Repo.update!()

      assert {:ok, ^sender} =
               EmailSending.resolve_booking_sender(Map.put(booking, :email_sender, sender))

      assert {:error, :settings_changed} = EmailSending.delivery_credentials(sender)

      assert {:ok, current} = EmailSending.resolve_booking_sender(booking)
      assert current == Sender.from_settings(updated)

      assert {:ok, credentials} = EmailSending.delivery_credentials(current)
      assert credentials.host == "smtp.changed.example"
      assert credentials.username == "updated-login"
      assert credentials.password == "updated-password"
    end

    test "disabled settings invalidate the old sender and resolve a new platform fallback", %{
      owner: owner
    } do
      stored = settings(owner)
      assert {:ok, sender} = EmailSending.resolve_booking_sender(resource(owner))
      assert {:ok, _disabled} = EmailSending.disable_settings(owner, {stored.id, stored.revision})

      assert {:error, :settings_changed} = EmailSending.delivery_credentials(sender)
      assert {:ok, platform} = EmailSending.resolve_booking_sender(resource(owner))
      assert platform == Sender.platform(owner.id)
    end

    test "deletion and recreation at the same revision cannot reuse the old settings identity", %{
      owner: owner
    } do
      stored = settings(owner)
      assert {:ok, sender} = EmailSending.resolve_booking_sender(resource(owner))
      assert :ok = EmailSending.delete_settings(owner, {stored.id, stored.revision})

      assert {:error, :settings_changed} = EmailSending.delivery_credentials(sender)

      assert {:ok, %Sender{kind: :platform}} =
               EmailSending.resolve_booking_sender(resource(owner))

      replacement = settings(owner)
      assert replacement.revision == sender.revision
      refute replacement.id == sender.settings_id
      assert {:error, :settings_changed} = EmailSending.delivery_credentials(sender)

      assert {:ok, current} = EmailSending.resolve_booking_sender(resource(owner))
      assert current == Sender.from_settings(replacement)
      assert {:ok, _credentials} = EmailSending.delivery_credentials(current)
    end

    test "deleting the owner prevents a previously resolved sender from loading credentials", %{
      owner: owner
    } do
      settings(owner)
      assert {:ok, sender} = EmailSending.resolve_booking_sender(resource(owner))
      Repo.delete!(owner)

      assert {:error, :settings_changed} = EmailSending.delivery_credentials(sender)
      assert {:error, :owner_not_found} = EmailSending.resolve_booking_sender(resource(owner))
    end

    test "unreadable saved credentials return a safe error without changing sender selection", %{
      owner: owner
    } do
      stored = settings(owner)
      assert {:ok, sender} = EmailSending.resolve_booking_sender(resource(owner))

      stored
      |> Changeset.change(password_encrypted: "unreadable ciphertext")
      |> Repo.update!()

      assert {:ok, ^sender} = EmailSending.resolve_booking_sender(resource(owner))
      assert {:error, :credentials_unavailable} = EmailSending.delivery_credentials(sender)
    end

    test "disabling the feature during an execution fails custom delivery closed", %{owner: owner} do
      settings(owner)
      booking = resource(owner)
      assert {:ok, sender} = EmailSending.resolve_booking_sender(booking)
      with_config(:tymeslot, user_smtp_enabled: false)

      assert {:ok, ^sender} =
               EmailSending.resolve_booking_sender(Map.put(booking, :email_sender, sender))

      assert {:error, :feature_disabled} = EmailSending.delivery_credentials(sender)
      assert {:ok, platform} = EmailSending.resolve_booking_sender(booking)
      assert platform == Sender.platform(owner.id)
    end
  end

  defp resource(owner), do: %{organizer_user_id: owner.id}

  # Resolution does not test SMTP: seed the same tested-row invariants as the
  # settings lifecycle so these boundary tests need no network fixture.
  defp settings(owner, attrs \\ %{}) do
    %UserSmtpSettingsSchema{
      user_id: owner.id,
      host: "smtp.customer.example",
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt("smtp-login-secret"),
      password_encrypted: Encryption.encrypt("smtp-password-secret"),
      from_address: "bookings@customer.example",
      from_name: "Customer bookings",
      enabled: true,
      revision: 1,
      tested_revision: 1,
      tested_at: DateTime.utc_now()
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end
end
