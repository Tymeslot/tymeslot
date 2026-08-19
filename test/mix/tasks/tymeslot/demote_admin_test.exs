defmodule Mix.Tasks.Tymeslot.DemoteAdminTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import ExUnit.CaptureIO
  import Tymeslot.Factory

  alias Mix.Tasks.Tymeslot.DemoteAdmin
  alias Tymeslot.Repo

  setup do
    Application.put_env(:tymeslot, :enable_admin_ui, true)
    on_exit(fn -> Application.put_env(:tymeslot, :enable_admin_ui, true) end)
    :ok
  end

  describe "run/1" do
    test "raises Mix.Error with usage message when no arguments are given" do
      assert_raise Mix.Error, ~r/Usage:/, fn ->
        DemoteAdmin.run([])
      end
    end

    test "raises Mix.Error with 'no user found' message for unknown email" do
      assert_raise Mix.Error, ~r/No user found/, fn ->
        capture_io(fn ->
          DemoteAdmin.run(["nobody@example.com"])
        end)
      end
    end

    test "demotes the admin user" do
      admin = insert(:user, is_admin: true)
      insert(:user, is_admin: true)

      capture_io(fn ->
        DemoteAdmin.run([admin.email])
      end)

      refute Repo.reload!(admin).is_admin
    end

    test "refuses to demote the only remaining admin without --force" do
      admin = insert(:user, is_admin: true)

      assert_raise Mix.Error, ~r/only remaining admin/, fn ->
        capture_io(fn ->
          DemoteAdmin.run([admin.email])
        end)
      end

      assert Repo.reload!(admin).is_admin
    end

    test "demotes the only remaining admin when --force is passed" do
      admin = insert(:user, is_admin: true)

      capture_io(fn ->
        DemoteAdmin.run(["--force", admin.email])
      end)

      refute Repo.reload!(admin).is_admin
    end
  end
end
