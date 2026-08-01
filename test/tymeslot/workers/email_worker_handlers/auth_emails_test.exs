defmodule Tymeslot.Workers.EmailWorkerHandlers.AuthEmailsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  import Mox
  import Tymeslot.Factory
  alias Tymeslot.Emails.Templates.PasswordReset
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Workers.EmailWorkerHandlers

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
end
