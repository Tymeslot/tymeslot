defmodule TymeslotWeb.BookingInvitationControllerTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :controllers
  @moduletag :bookings

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Phoenix.Flash
  alias Tymeslot.Invitations
  alias Tymeslot.Repo
  alias TymeslotWeb.Live.Scheduling.InvitationMessages

  setup do
    user = insert(:user)
    insert(:profile, user: user, username: "invitehost")

    type =
      insert(:meeting_type, user: user, name: "Coaching", slug: "coaching", invitation_only: true)

    {:ok, invitation} = Invitations.create(user.id, type, %{})
    %{user: user, type: type, invitation: invitation}
  end

  test "a valid invitation redirects to the meeting type with the token", %{
    conn: conn,
    invitation: invitation
  } do
    conn = get(conn, "/invite/#{invitation.token}")

    assert redirected_to(conn, 302) ==
             "/invitehost/coaching?invite=" <> URI.encode_www_form(invitation.token)

    assert Enum.join(get_resp_header(conn, "cache-control")) =~ "no-store"
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  describe "a link that can no longer book redirects to the profile with a message" do
    test "used", %{conn: conn, user: user, invitation: invitation} do
      insert(:meeting, organizer_user: user, status: :confirmed, invitation_id: invitation.id)

      assert_refused(conn, invitation, :used)
    end

    test "expired", %{conn: conn, invitation: invitation} do
      invitation
      |> Changeset.change(
        expires_at: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert_refused(conn, invitation, :expired)
    end

    test "revoked", %{conn: conn, user: user, invitation: invitation} do
      {:ok, _revoked} = Invitations.revoke(user.id, invitation.id)

      assert_refused(conn, invitation, :revoked)
    end
  end

  test "an unknown token is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/invite/not-a-real-token") end
  end

  test "a type no longer invitation-only is a 404", %{
    conn: conn,
    type: type,
    invitation: invitation
  } do
    type |> Changeset.change(invitation_only: false) |> Repo.update!()

    assert_error_sent 404, fn -> get(conn, "/invite/#{invitation.token}") end
  end

  describe "rate limiting" do
    test "too many requests from one address get a 429 before the token is looked at", %{
      conn: conn,
      invitation: invitation
    } do
      # An address of its own, so no other test's requests share the bucket.
      conn = %{conn | remote_ip: {198, 51, 100, rem(System.unique_integer([:positive]), 250) + 1}}

      for _attempt <- 1..30 do
        assert conn
               |> recycle_with_ip()
               |> get("/invite/#{invitation.token}")
               |> redirected_to(302)
      end

      refused = conn |> recycle_with_ip() |> get("/invite/#{invitation.token}")

      assert text_response(refused, 429) == "Too Many Requests"
      refute response(refused, 429) =~ invitation.token
      assert get_resp_header(refused, "location") == []
      assert Enum.join(get_resp_header(refused, "cache-control")) =~ "no-store"

      # The refusal is per address: another client still follows its link.
      other = %{build_conn() | remote_ip: {192, 0, 2, 77}}
      assert other |> get("/invite/#{invitation.token}") |> redirected_to(302)
    end
  end

  defp recycle_with_ip(conn), do: %{recycle(conn) | remote_ip: conn.remote_ip}

  defp assert_refused(conn, invitation, reason) do
    conn = get(conn, "/invite/#{invitation.token}")

    assert redirected_to(conn, 302) == "/invitehost"
    assert Flash.get(conn.assigns.flash, :error) == InvitationMessages.message(reason)
    refute Flash.get(conn.assigns.flash, :error) =~ invitation.token
  end
end
