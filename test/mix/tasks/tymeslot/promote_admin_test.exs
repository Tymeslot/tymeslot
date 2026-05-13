defmodule Mix.Tasks.Tymeslot.PromoteAdminTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import ExUnit.CaptureIO
  import Tymeslot.Factory

  alias Mix.Tasks.Tymeslot.PromoteAdmin
  alias Tymeslot.Repo

  setup do
    Application.put_env(:tymeslot, :enable_admin_ui, true)
    on_exit(fn -> Application.put_env(:tymeslot, :enable_admin_ui, true) end)
    :ok
  end

  describe "run/1" do
    test "raises Mix.Error with usage message when no arguments are given" do
      assert_raise Mix.Error, ~r/Usage:/, fn ->
        PromoteAdmin.run([])
      end
    end

    test "raises Mix.Error with 'no user found' message for unknown email" do
      assert_raise Mix.Error, ~r/No user found/, fn ->
        capture_io(fn ->
          PromoteAdmin.run(["nobody@example.com"])
        end)
      end
    end

    test "promotes the user to admin" do
      user = insert(:user, is_admin: false)

      capture_io(fn ->
        PromoteAdmin.run([user.email])
      end)

      assert Repo.reload!(user).is_admin
    end
  end
end
