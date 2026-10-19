defmodule Tymeslot.Auth.SessionLeaveConnectedTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import Tymeslot.Factory

  alias Phoenix.Socket.Broadcast
  alias Tymeslot.Auth.{Session, UserSessionQueries}
  alias Tymeslot.Security.Token
  alias TymeslotWeb.Endpoint

  defp topic(token), do: "users_sessions:#{Base.url_encode64(Token.hash_token(token))}"

  defp session_for(user) do
    token = "session-#{System.unique_integer([:positive])}"
    insert(:user_session, user: user, token_hash: Token.hash_token(token))
    Endpoint.subscribe(topic(token))
    token
  end

  test "ends every session but leaves the named session's socket connected" do
    user = insert(:user)
    current = session_for(user)
    other = session_for(user)
    current_topic = topic(current)
    other_topic = topic(other)

    assert Session.revoke_all_sessions(user.id, leave_connected: current) == :ok

    assert UserSessionQueries.get_user_by_session_token(current) == nil
    assert UserSessionQueries.get_user_by_session_token(other) == nil
    assert_receive %Broadcast{event: "disconnect", topic: ^other_topic}
    refute_receive %Broadcast{event: "disconnect", topic: ^current_topic}
  end
end
