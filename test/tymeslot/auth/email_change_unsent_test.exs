defmodule Tymeslot.Auth.EmailChangeUnsentTest do
  @moduledoc """
  An email change whose emails cannot be queued says so, rather than telling
  the user a link is on its way. A taken address is answered the same way as
  a free one, so the failure cannot reveal which addresses are registered.
  """

  # async: false: the email inserts are refused by patching Oban.insert/1 with
  # :meck, which replaces the module for every process.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import ExUnit.CaptureLog
  import Tymeslot.Factory

  @moduletag :auth

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Helpers.ClientIP

  @unsent "The verification email could not be sent. Please try again."

  test "a change whose emails cannot be queued is reported, and asking again sends them" do
    user = insert(:user)

    refusing_email_change_jobs(fn ->
      assert {:error, %{new_email: @unsent}} = request(user, "new.address@example.com")
    end)

    assert all_enqueued(worker: EmailWorker) == []

    assert {:ok, _user, "Verification email sent to new.address@example.com"} =
             request(user, "new.address@example.com")

    assert [_verification] =
             all_enqueued(
               worker: EmailWorker,
               args: %{"action" => "send_email_change_verification"}
             )
  end

  test "a taken address whose notice cannot be queued is answered as a free one would be" do
    user = insert(:user)
    other = insert(:user)

    refusing_email_change_jobs(fn ->
      assert {:error, %{new_email: @unsent}} = request(user, other.email)
    end)
  end

  defp request(user, new_email) do
    capture_log(fn ->
      send(
        self(),
        {:result,
         Auth.request_email_change(
           user,
           new_email,
           "Password123!",
           ClientIP.request_opts(%Plug.Conn{})
         )}
      )
    end)

    assert_received {:result, result}
    result
  end

  # Only the notice to the current address is refused: the verification email
  # inserts first, so this also shows the two commit together or not at all.
  defp refusing_email_change_jobs(fun) do
    :meck.new(Oban, [:passthrough])

    :meck.expect(Oban, :insert, fn changeset ->
      if Changeset.get_field(changeset, :args)["action"] == "send_email_change_notification",
        do: {:error, :queue_not_available},
        else: :meck.passthrough([changeset])
    end)

    try do
      fun.()
    after
      :meck.unload(Oban)
    end
  end
end
