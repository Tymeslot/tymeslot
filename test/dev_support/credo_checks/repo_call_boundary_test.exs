Code.require_file(
  "dev_support/credo_checks/repo_call_boundary.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.RepoCallBoundaryTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.RepoCallBoundary

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "allowed files" do
    test "no issues for *_queries.ex files" do
      """
      defmodule Tymeslot.Users.Queries do
        alias Tymeslot.Repo

        def get_user(id), do: Repo.get(User, id)
        def list_users, do: Repo.all(User)
      end
      """
      |> to_source_file("lib/tymeslot/users/user_queries.ex")
      |> run_check(RepoCallBoundary)
      |> refute_issues()
    end

    test "no issues for *_schema.ex files" do
      """
      defmodule Tymeslot.Users.UserSchema do
        alias Tymeslot.Repo

        def changeset_and_insert(attrs) do
          Repo.insert(%User{})
        end
      end
      """
      |> to_source_file("lib/tymeslot/users/user_schema.ex")
      |> run_check(RepoCallBoundary)
      |> refute_issues()
    end

    test "no issues for test files" do
      """
      defmodule Tymeslot.UsersTest do
        alias Tymeslot.Repo

        def create do
          Repo.insert!(%User{name: "test"})
        end
      end
      """
      |> to_source_file("test/tymeslot/users_test.exs")
      |> run_check(RepoCallBoundary)
      |> refute_issues()
    end

    test "no issues for migration files" do
      """
      defmodule Tymeslot.Repo.Migrations.AddUsers do
        use Ecto.Migration

        def change do
          Repo.update_all(User, set: [active: true])
        end
      end
      """
      |> to_source_file("priv/repo/migrations/20260101000000_add_users.exs")
      |> run_check(RepoCallBoundary)
      |> refute_issues()
    end

    test "no issues for repo.ex itself" do
      """
      defmodule Tymeslot.Repo do
        use Ecto.Repo, otp_app: :tymeslot
      end
      """
      |> to_source_file("lib/tymeslot/repo.ex")
      |> run_check(RepoCallBoundary)
      |> refute_issues()
    end
  end

  describe "allowed functions" do
    test "Repo.transaction is allowed everywhere" do
      """
      defmodule Tymeslot.Users do
        alias Tymeslot.Repo

        def create_user(attrs) do
          Repo.transaction(fn -> :ok end)
        end
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> refute_issues()
    end

    test "Repo.rollback is allowed everywhere" do
      """
      defmodule Tymeslot.Users do
        alias Tymeslot.Repo

        def abort do
          Repo.rollback(:cancelled)
        end
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> refute_issues()
    end

    test "Repo.preload is allowed everywhere" do
      """
      defmodule Tymeslot.Users do
        alias Tymeslot.Repo

        def load_profile(user) do
          Repo.preload(user, :profile)
        end
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> refute_issues()
    end
  end

  describe "flagged calls" do
    test "Repo.get in a regular file is flagged" do
      """
      defmodule Tymeslot.Users do
        alias Tymeslot.Repo

        def get_user(id), do: Repo.get(User, id)
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "Repo.get" end)
    end

    test "Repo.insert! in a regular file is flagged" do
      """
      defmodule Tymeslot.Users do
        alias Tymeslot.Repo

        def create!(attrs) do
          Repo.insert!(%User{})
        end
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "Repo.insert!" end)
    end

    test "Repo.all in a regular file is flagged" do
      """
      defmodule Tymeslot.Users do
        alias Tymeslot.Repo

        def list_all, do: Repo.all(User)
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "Repo.all" end)
    end

    test "Repo.delete_all in a regular file is flagged" do
      """
      defmodule Tymeslot.Users do
        alias Tymeslot.Repo

        def purge, do: Repo.delete_all(User)
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "Repo.delete_all" end)
    end

    test "multiple Repo calls are all flagged" do
      """
      defmodule Tymeslot.Users do
        alias Tymeslot.Repo

        def get_user(id), do: Repo.get(User, id)
        def list_all, do: Repo.all(User)
        def create(attrs), do: Repo.insert(%User{})
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> assert_issues(3)
    end

    test "fully qualified Tymeslot.Repo.get is flagged" do
      """
      defmodule Tymeslot.Users do
        def get_user(id), do: Tymeslot.Repo.get(User, id)
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "Tymeslot.Repo.get" end)
    end

    test "SaasRepo call is flagged (any module ending in Repo)" do
      """
      defmodule Tymeslot.Legal do
        alias Tymeslot.SaasRepo

        def get_acceptance(id), do: SaasRepo.get(Acceptance, id)
      end
      """
      |> to_source_file("lib/tymeslot/legal.ex")
      |> run_check(RepoCallBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "SaasRepo.get" end)
    end

    test "fully qualified Tymeslot.SaasRepo.all is flagged" do
      """
      defmodule Tymeslot.Legal do
        def list, do: Tymeslot.SaasRepo.all(Acceptance)
      end
      """
      |> to_source_file("lib/tymeslot/legal.ex")
      |> run_check(RepoCallBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "Tymeslot.SaasRepo.all" end)
    end

    test "Repo renamed via `as:` is flagged" do
      """
      defmodule Tymeslot.Users do
        alias Tymeslot.Repo, as: DB

        def get_user(id), do: DB.get(User, id)
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "DB.get" end)
    end

    test "SaasRepo renamed via `as:` is flagged" do
      """
      defmodule Tymeslot.Legal do
        alias Tymeslot.SaasRepo, as: DB

        def list, do: DB.all(Acceptance)
      end
      """
      |> to_source_file("lib/tymeslot/legal.ex")
      |> run_check(RepoCallBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "DB.all" end)
    end
  end

  describe "no false positives for non-repo aliases" do
    test "a non-repo single-segment alias is not flagged" do
      """
      defmodule Tymeslot.Users do
        alias Tymeslot.Cache, as: DB

        def fetch(id), do: DB.get(id)
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> refute_issues()
    end

    test "a non-repo qualified module call is not flagged" do
      """
      defmodule Tymeslot.Users do
        def fetch(id), do: Tymeslot.Cache.get(id)
      end
      """
      |> to_source_file("lib/tymeslot/users.ex")
      |> run_check(RepoCallBoundary)
      |> refute_issues()
    end
  end
end
