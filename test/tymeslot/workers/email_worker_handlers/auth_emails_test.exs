defmodule Tymeslot.Workers.EmailWorkerHandlers.AuthEmailsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  import Mox
  import Tymeslot.Factory
  alias Tymeslot.Emails.EmailScheduler.LinkArg
  alias Tymeslot.Emails.Templates.PasswordReset
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Workers.EmailWorkerHandlers
  alias TymeslotWeb.Endpoint

  setup :verify_on_exit!

  describe "recipient loading" do
    test "hands the email service a user whose profile name can be greeted" do
      # An email/password signup never gets a `user.name` — the signup form has
      # no name field — so unless the handler loads the profile the recipient is
      # greeted "Hi there," for the life of the account.
      user = insert(:user, name: nil)
      insert(:profile, user: user, full_name: "Ada Lovelace")
      reset_url = "https://example.com/reset/token"
      parent = self()

      expect(EmailServiceMock, :send_password_reset, fn loaded_user, _url ->
        send(parent, {:password_reset_recipient, loaded_user})
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_password_reset", %{
                 "user_id" => user.id,
                 "reset_url" => reset_url
               })

      assert_receive {:password_reset_recipient, recipient}
      assert PasswordReset.render_text(recipient, reset_url) =~ "Hi Ada Lovelace,"
    end

    test "greets an OAuth user by their signup name before onboarding runs" do
      user = insert(:user, name: "Ada from GitHub", provider: "github")
      reset_url = "https://example.com/reset/token"
      parent = self()

      expect(EmailServiceMock, :send_password_reset, fn loaded_user, _url ->
        send(parent, {:password_reset_recipient, loaded_user})
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_password_reset", %{
                 "user_id" => user.id,
                 "reset_url" => reset_url
               })

      assert_receive {:password_reset_recipient, recipient}
      assert PasswordReset.render_text(recipient, reset_url) =~ "Hi Ada from GitHub,"
    end
  end

  describe "account notices" do
    test "the no-password notice goes to the account with a sign-in link" do
      user = insert(:user, provider: "google", password_hash: nil)
      parent = self()

      expect(EmailServiceMock, :send_no_password_to_reset, fn recipient, sign_in_url ->
        send(parent, {:notice, recipient.id, sign_in_url})
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_no_password_to_reset", %{
                 "user_id" => user.id
               })

      assert_receive {:notice, user_id, sign_in_url}
      assert user_id == user.id
      assert sign_in_url == Endpoint.url() <> "/auth/login"
    end

    test "the sign-up attempt notice links to sign in and to the reset form" do
      user = insert(:user)
      parent = self()

      expect(EmailServiceMock, :send_signup_attempt_notice, fn recipient, sign_in, reset ->
        send(parent, {:notice, recipient.id, sign_in, reset})
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_signup_attempt_notice", %{
                 "user_id" => user.id
               })

      assert_receive {:notice, user_id, sign_in, reset}
      assert user_id == user.id
      assert sign_in == Endpoint.url() <> "/auth/login"
      assert reset == Endpoint.url() <> "/auth/reset-password"
    end

    test "a notice for an account deleted since is discarded" do
      assert {:discard, _reason} =
               EmailWorkerHandlers.execute_email_action("send_signup_attempt_notice", %{
                 "user_id" => -1
               })
    end

    test "a failed send is retried" do
      user = insert(:user)

      expect(EmailServiceMock, :send_no_password_to_reset, fn _user, _url ->
        {:error, :timeout}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_no_password_to_reset", %{
                 "user_id" => user.id
               })
    end
  end

  describe "sign-up confirmation" do
    test "decrypts the link and sends it to the typed address in the form's locale" do
      parent = self()
      url = "https://example.com/auth/oauth/confirm/token"

      expect(EmailServiceMock, :send_social_signup_confirmation, fn recipient, provider, link ->
        send(parent, {:confirmation, recipient, provider, link})
        {:ok, "sent"}
      end)

      args =
        LinkArg.put(
          %{
            "email" => "typed@example.com",
            "name" => "Ada",
            "provider" => "github",
            "locale" => "fr"
          },
          "confirm_url",
          url
        )

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_social_signup_confirmation", args)

      assert_receive {:confirmation, recipient, "github", ^url}
      assert recipient.email == "typed@example.com"
      assert recipient.locale == "fr"
    end

    test "a job whose link cannot be read is discarded" do
      assert {:discard, _reason} =
               EmailWorkerHandlers.execute_email_action("send_social_signup_confirmation", %{
                 "email" => "typed@example.com",
                 "provider" => "github"
               })
    end
  end
end
