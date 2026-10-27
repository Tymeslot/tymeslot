defmodule Tymeslot.Emails.EmailScheduler.HelpersTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails

  import ExUnit.CaptureLog

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  describe "insert/3" do
    defp unique_job(args) do
      EmailWorker.new(args,
        unique: [period: 300, fields: [:args, :queue], keys: [:action, :user_id]]
      )
    end

    test "schedules a job, then reports the same job again as a duplicate" do
      args = %{"action" => "send_no_password_to_reset", "user_id" => 1}

      assert {:ok, :scheduled} = args |> unique_job() |> Helpers.insert(user_id: 1)
      assert {:ok, :duplicate} = args |> unique_job() |> Helpers.insert(user_id: 1)
      assert [_one] = all_enqueued(worker: EmailWorker)
    end

    test "returns an insert Oban refuses, as Oban gave it" do
      # Oban's own changeset refuses a priority outside 0..9.
      changeset = EmailWorker.new(%{"action" => "send_confirmation_emails"}, priority: 10)

      log =
        capture_log(fn ->
          assert {:error, %Changeset{valid?: false}} = Helpers.insert(changeset, user_id: 1)
        end)

      assert log =~ "Failed to schedule email job"
      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  describe "ok/1" do
    test "takes a duplicate for a schedule and passes an error through" do
      assert Helpers.ok({:ok, :scheduled}) == :ok
      assert Helpers.ok({:ok, :duplicate}) == :ok
      assert Helpers.ok({:error, :down}) == {:error, :down}
    end
  end

  describe "format_insert_error/1" do
    test "traverses changeset errors into a plain map" do
      changeset =
        {%{}, %{name: :string}}
        |> Changeset.cast(%{}, [:name])
        |> Changeset.validate_required([:name])

      assert %{name: ["can't be blank"]} = Helpers.format_insert_error(changeset)
    end

    test "inspects non-changeset terms as strings" do
      assert Helpers.format_insert_error(:some_error) == ":some_error"
      assert Helpers.format_insert_error("raw string") == ~s("raw string")
      assert Helpers.format_insert_error({:error, 404}) == "{:error, 404}"
    end

    test "redacts a credential inside a non-changeset term" do
      formatted = Helpers.format_insert_error({:error, %{"api_key" => "sk-leak", code: 500}})

      assert formatted =~ "[REDACTED]"
      assert formatted =~ "500"
      refute formatted =~ "sk-leak"
    end
  end
end
