defmodule TymeslotWeb.Plugs.SetLoggerMetadataTest do
  @moduledoc false

  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs

  require Logger

  alias Tymeslot.Factory
  alias TymeslotWeb.Plugs.SetLoggerMetadata

  describe "init/1" do
    test "passes options through unchanged" do
      assert SetLoggerMetadata.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2" do
    setup do
      on_exit(fn -> Logger.metadata(user_id: nil) end)
      :ok
    end

    test "sets user_id in Logger metadata when current_user is assigned", %{conn: conn} do
      user = Factory.insert(:user)

      conn =
        conn
        |> assign(:current_user, user)
        |> SetLoggerMetadata.call([])

      assert Logger.metadata()[:user_id] == user.id
      refute conn.halted
    end

    test "does not set user_id when no current_user", %{conn: conn} do
      Logger.metadata(user_id: nil)

      _conn = SetLoggerMetadata.call(conn, [])

      refute Logger.metadata()[:user_id]
    end

    test "returns conn unchanged", %{conn: conn} do
      result = SetLoggerMetadata.call(conn, [])

      assert result == conn
    end
  end
end
