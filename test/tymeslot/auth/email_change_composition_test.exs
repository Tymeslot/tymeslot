defmodule Tymeslot.Auth.EmailChangeCompositionTest do
  @moduledoc """
  End-to-end composition coverage for
  `Tymeslot.Auth.EmailChange.request_email_change/3` →
  `Tymeslot.Auth.EmailChange.verify_email_change/1`.

  The unit suite (`email_change_test.exs`) asserts on each side of the
  boundary — request sets `pending_email` + enqueues Oban jobs, verify
  swaps the email + clears the token — but never joins them in a single
  test. This file joins them and asserts the end state the user sees:

    old email → request change → verification email job enqueued →
    user clicks the confirmation link → new email active,
    `pending_email` cleared, **every** session gone, and a
    confirmation email enqueued for the old and new addresses.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Auth.EmailChange
  alias Tymeslot.Auth.{UserQueries, UserSessionSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  describe "request_email_change + verify_email_change — full pipeline" do
    test "round-trips old → new email, invalidates sessions, and schedules every downstream email" do
      user = insert(:user)
      _session_a = insert(:user_session, user: user)
      _session_b = insert(:user_session, user: user)

      assert length(sessions_for(user.id)) == 2

      new_email = "rotated-#{System.unique_integer([:positive])}@example.com"

      # Step 1: request the change — persists pending_email and enqueues the
      # verification + notification emails.
      assert {:ok, requested_user, _msg} =
               EmailChange.request_email_change(user, new_email, "Password123!")

      assert requested_user.pending_email == new_email
      assert requested_user.email_change_token_hash
      assert requested_user.email_change_sent_at

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_change_verification",
          "user_id" => user.id,
          "new_email" => new_email
        }
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_change_notification",
          "user_id" => user.id,
          "new_email" => new_email
        }
      )

      # Step 2: pull the raw verification token out of the enqueued verification
      # URL (the user clicks this in their email client).
      [verification_job] =
        all_enqueued(
          worker: EmailWorker,
          args: %{"action" => "send_email_change_verification", "user_id" => user.id}
        )

      raw_token = extract_token_from_url(verification_job.args["verification_url"])

      # Step 3: verify — swaps the email, clears pending state, invalidates
      # sessions, enqueues the post-change confirmation emails.
      assert {:ok, verified_user, _msg} = EmailChange.verify_email_change(raw_token)
      assert verified_user.email == new_email
      assert is_nil(verified_user.pending_email)
      assert is_nil(verified_user.email_change_token_hash)
      assert verified_user.email_change_confirmed_at

      # All sessions are gone — the user must re-authenticate with the new address.
      assert sessions_for(user.id) == []

      # And the confirmation-to-both-addresses job is now scheduled.
      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_change_confirmations",
          "user_id" => user.id,
          "old_email" => user.email,
          "new_email" => new_email
        }
      )

      # The old email is no longer associated with the account.
      assert {:error, :not_found} = UserQueries.get_user_by_email(user.email)
      assert {:ok, ^verified_user} = UserQueries.get_user_by_email(new_email)
    end
  end

  # The verification URL is built by UrlBuilder.email_change_url/1 and ends in
  # /.../<token>. The token is whatever trailing path segment it produced.
  defp extract_token_from_url(url) do
    url |> URI.parse() |> Map.fetch!(:path) |> String.split("/") |> List.last()
  end

  defp sessions_for(user_id) do
    import Ecto.Query
    Repo.all(from s in UserSessionSchema, where: s.user_id == ^user_id)
  end
end
