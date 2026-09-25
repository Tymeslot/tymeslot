defmodule Tymeslot.Auth.AccountDeletionSessionsTest do
  @moduledoc """
  Deleting an account ends its sessions everywhere, including LiveView
  sockets that are already connected. The session rows go with the user
  (FK cascade), but a connected socket never looks at them again, so without
  a disconnect broadcast a deleted user's open dashboard tab kept running.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :auth

  import Tymeslot.Factory

  alias Phoenix.Socket.Broadcast
  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSessionQueries
  alias Tymeslot.Security.Token
  alias TymeslotWeb.Endpoint

  defp live_socket_topic(token),
    do: "users_sessions:#{Base.url_encode64(Token.hash_token(token))}"

  defp session_for(user) do
    token = "session-#{System.unique_integer([:positive])}"
    insert(:user_session, user: user, token_hash: Token.hash_token(token))
    token
  end

  test "disconnects the live socket of every session the user held" do
    user = insert(:user)
    tokens = [session_for(user), session_for(user)]
    topics = Enum.map(tokens, &live_socket_topic/1)
    Enum.each(topics, &Endpoint.subscribe/1)

    assert {:ok, _deleted} = Auth.delete_account(user)

    for topic <- topics do
      assert_receive %Broadcast{topic: ^topic, event: "disconnect"}
    end

    assert Enum.map(tokens, &UserSessionQueries.get_user_by_session_token/1) == [nil, nil]
  end

  test "leaves another user's sessions connected" do
    user = insert(:user)
    other = insert(:user)
    _own_token = session_for(user)
    other_token = session_for(other)
    Endpoint.subscribe(live_socket_topic(other_token))

    assert {:ok, _deleted} = Auth.delete_account(user)

    refute_receive %Broadcast{event: "disconnect"}
    assert UserSessionQueries.get_user_by_session_token(other_token)
  end
end
