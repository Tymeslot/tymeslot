defmodule Tymeslot.Infrastructure.CrashReporterTest.CrashingServer do
  use GenServer

  @spec start(term()) :: GenServer.on_start()
  def start(name), do: GenServer.start(__MODULE__, nil, name: name)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_cast(:crash, _state), do: raise("genserver boom")
end

defmodule Tymeslot.Infrastructure.CrashReporterTest.CrashingLive do
  use Phoenix.LiveView

  @impl Phoenix.LiveView
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl Phoenix.LiveView
  def render(assigns), do: ~H"<div>ready</div>"

  @impl Phoenix.LiveView
  def handle_event("crash", _params, _socket), do: raise("handle_event boom")

  @impl Phoenix.LiveView
  def handle_info(:crash, _socket), do: raise("handle_info boom")
end

defmodule Tymeslot.Infrastructure.CrashReporterTest.BodyCrashComponent do
  use Phoenix.LiveComponent

  @impl Phoenix.LiveComponent
  def render(assigns), do: ~H"<div></div>"

  @impl Phoenix.LiveComponent
  def handle_event("known", params, socket) do
    {:noreply, assign(socket, :picked, pick(params))}
  end

  defp pick(%{"id" => id}), do: id
end

defmodule Tymeslot.Infrastructure.CrashReporterTest.RaisingIgnorer do
  @spec ignore?(term(), map()) :: no_return()
  def ignore?(_error, _context) do
    send(Application.get_env(:tymeslot, :crash_reporter_test_pid), :ignorer_invoked)
    raise "ignorer blew up"
  end
end

defmodule Tymeslot.Infrastructure.CrashReporterTest do
  @moduledoc false

  # async: false: the `:logger` handler, the telemetry handler and
  # ErrorTracker's `enabled` switch are all global.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :infrastructure

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.CrashReporter
  alias Tymeslot.Infrastructure.CrashReporterTest.BodyCrashComponent
  alias Tymeslot.Infrastructure.CrashReporterTest.CrashingLive
  alias Tymeslot.Infrastructure.CrashReporterTest.CrashingServer
  alias Tymeslot.Infrastructure.CrashReporterTest.RaisingIgnorer
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Repo
  alias TymeslotWeb.Components.UserDropdownComponent

  @telemetry_handler "crash-reporter-test-occurrences"

  @doc false
  @spec forward_occurrence([atom()], map(), map(), pid()) :: :ok
  def forward_occurrence(_event, _measurements, %{occurrence: occurrence}, test_pid) do
    send(test_pid, {:occurrence_recorded, occurrence})
    :ok
  end

  setup do
    with_config(:error_tracker, enabled: true)

    :ok =
      :telemetry.attach(
        @telemetry_handler,
        [:error_tracker, :occurrence, :new],
        &__MODULE__.forward_occurrence/4,
        self()
      )

    :ok = CrashReporter.attach()

    on_exit(fn ->
      :telemetry.detach(@telemetry_handler)
      CrashReporter.detach()
    end)

    :ok
  end

  defp errors, do: Repo.all(from(e in Error, preload: :occurrences))

  defp occurrence_count, do: Repo.aggregate(Occurrence, :count)

  # Every assertion below waits on ErrorTracker's own `occurrence:new` event,
  # so it holds however long the offloaded report takes.
  defp await_occurrence! do
    assert_receive {:occurrence_recorded, occurrence}, 2_000
    occurrence
  end

  defp refute_occurrence, do: refute_receive({:occurrence_recorded, _occurrence}, 300)

  defp crash_task(fun) do
    {:ok, pid} = Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fun)
    pid
  end

  # Fills the bounded recording supervisor, so the next report finds no room.
  defp occupy_recording_tasks do
    supervisor = ErrorTracking.task_supervisor()

    Stream.repeatedly(fn ->
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          :release -> :ok
        end
      end)
    end)
    |> Enum.take_while(&match?({:ok, _pid}, &1))
    |> Enum.map(fn {:ok, pid} -> pid end)
  end

  describe "reportable?/2" do
    test "orderly exits are not reportable" do
      refute CrashReporter.reportable?(:exit, :normal)
      refute CrashReporter.reportable?(:exit, :shutdown)
      refute CrashReporter.reportable?(:exit, {:shutdown, :boom})
    end

    test "exceptions, throws and abnormal exits are reportable" do
      assert CrashReporter.reportable?(:error, %RuntimeError{message: "boom"})
      assert CrashReporter.reportable?(:throw, :some_value)
      assert CrashReporter.reportable?(:exit, :boom)
    end
  end

  describe "a crash outside Phoenix and Oban" do
    # The crash travels through the :logger handler attach/0 installed, so the
    # production code under test is invoked by the runtime, not by this body.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "a crashing GenServer is recorded once, with its registered name" do
      CaptureLog.capture_log(fn ->
        {:ok, _pid} = CrashingServer.start(:crash_reporter_test_server)
        GenServer.cast(:crash_reporter_test_server, :crash)

        occurrence = await_occurrence!()
        refute_occurrence()

        assert occurrence.reason == "genserver boom"
        assert occurrence.context["process.registered_name"] == ":crash_reporter_test_server"
      end)

      assert [%Error{kind: "Elixir.RuntimeError", occurrences: [_one]}] = errors()
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "a crashing supervised Task is recorded once" do
      CaptureLog.capture_log(fn ->
        crash_task(fn -> raise "task boom" end)

        assert await_occurrence!().reason == "task boom"
        refute_occurrence()
      end)

      assert [%Error{kind: "Elixir.RuntimeError", occurrences: [_one]}] = errors()
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "a throw and an abnormal exit are recorded under their kinds" do
      CaptureLog.capture_log(fn ->
        crash_task(fn -> throw(:thrown) end)
        await_occurrence!()

        crash_task(fn -> exit(:went_wrong) end)
        await_occurrence!()
      end)

      assert errors() |> Enum.map(& &1.kind) |> Enum.sort() == ["exit", "throw"]
    end

    test "a crash arriving while every recording task is busy is dropped and counted" do
      test_pid = self()
      handler_id = "crash-reporter-test-dropped"

      :ok =
        :telemetry.attach(
          handler_id,
          [:tymeslot, :crash_reporter, :dropped],
          fn _event, measurements, _metadata, _config ->
            send(test_pid, {:dropped, measurements})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      blockers = occupy_recording_tasks()

      CaptureLog.capture_log(fn ->
        crash_task(fn -> raise "crash while busy" end)

        assert_receive {:dropped, %{count: 1}}, 2_000
        refute_occurrence()
      end)

      Enum.each(blockers, &send(&1, :release))
      assert errors() == []
    end

    test "an orderly exit is not recorded" do
      CaptureLog.capture_log(fn ->
        pid =
          crash_task(fn ->
            receive do
              :go -> exit({:shutdown, :done})
            end
          end)

        ref = Process.monitor(pid)
        send(pid, :go)
        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :done}}, 2_000
        refute_occurrence()
      end)

      assert errors() == []
    end

    test "a 4xx exception in a process serving a LiveView is not recorded" do
      CaptureLog.capture_log(fn ->
        crash_task(fn ->
          ErrorTracker.set_context(%{"live_view.view" => "TymeslotWeb.DashboardLive"})
          raise Ecto.NoResultsError, queryable: "users"
        end)

        refute_occurrence()
      end)

      assert errors() == []
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the same 4xx exception in a background task is recorded" do
      CaptureLog.capture_log(fn ->
        crash_task(fn -> raise Ecto.NoResultsError, queryable: "users" end)
        await_occurrence!()
      end)

      assert [%Error{kind: "Elixir.Ecto.NoResultsError"}] = errors()
    end
  end

  describe "a crash ErrorTracker's integrations already record" do
    setup :setup_dashboard_user

    # The LiveView integration records the event's exception in the LiveView
    # process, and the process then crashes and logs it again. One occurrence.
    test "a LiveView event crash is stored once, not twice", %{conn: conn} do
      Process.flag(:trap_exit, true)
      {:ok, view, _html} = live_isolated(conn, CrashingLive)

      CaptureLog.capture_log(fn ->
        catch_exit(render_click(view, "crash", %{}))

        assert await_occurrence!().context["live_view.event"] == "crash"
        refute_occurrence()
      end)

      assert occurrence_count() == 1
    end

    # A real LiveView sent an event its handle_event/3 clauses do not match
    # (`onboarding:toggle` without its `id`): a forged or stale client. The
    # integration's report is ignored, and the crash log that follows is only
    # a warning. Nothing is stored, so nothing can alert.
    test "an unmatched event on a real LiveView is not stored", %{conn: conn} do
      Process.flag(:trap_exit, true)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      log =
        CaptureLog.capture_log(fn ->
          catch_exit(render_click(view, "onboarding:toggle", %{}))
          refute_occurrence()
        end)

      assert log =~ "no handle_event/3 clause matches"
      assert log =~ "onboarding:toggle"
      assert occurrence_count() == 0
    end

    # No integration covers handle_info/2, so the crash log is the only record.
    test "a LiveView handle_info crash is still recorded", %{conn: conn} do
      Process.flag(:trap_exit, true)
      {:ok, view, _html} = live_isolated(conn, CrashingLive)

      CaptureLog.capture_log(fn ->
        send(view.pid, :crash)

        occurrence = await_occurrence!()
        refute_occurrence()

        assert occurrence.reason == "handle_info boom"
        assert occurrence.context["live_view.view"] == CrashingLive
      end)

      assert occurrence_count() == 1
    end
  end

  describe "a process that reported an exception directly" do
    # Reports the exception it handled, carries on, then crashes with an
    # exception of the same kind and message.
    defp report_then_crash(report) do
      crash_task(fn ->
        report.(fn -> ErrorTracker.report(%RuntimeError{message: "same boom"}, [], %{}) end)
        raise "same boom"
      end)
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "inside with_direct_report/1, its later crash is still recorded" do
      CaptureLog.capture_log(fn ->
        report_then_crash(&ErrorTracking.with_direct_report/1)

        await_occurrence!()
        await_occurrence!()
      end)

      assert occurrence_count() == 2
    end

    # The reason the hook exists: without it the direct report is taken for
    # an integration's, and the crash that follows is skipped.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "outside it, the later crash is taken as already recorded" do
      CaptureLog.capture_log(fn ->
        report_then_crash(fn report -> report.() end)

        await_occurrence!()
        refute_occurrence()
      end)

      assert occurrence_count() == 1
    end
  end

  describe "events no handle_event/3 clause matches" do
    # The client names both the event and the component it targets, so any
    # signed-in user can produce this crash at will. The real dropdown
    # component, crashed the way a forged socket frame crashes it.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "a forged event name aimed at a real component logs a warning instead" do
      log =
        CaptureLog.capture_log(fn ->
          crash_task(fn ->
            UserDropdownComponent.handle_event(
              "open_refund_modal",
              %{},
              %Phoenix.LiveView.Socket{}
            )
          end)

          refute_occurrence()
        end)

      assert log =~ "no handle_event/3 clause matches"
      assert log =~ "open_refund_modal"
    end

    # A clause matched and its body then failed: a real bug, whoever sent the
    # event, and it must still be recorded.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "a function clause error raised inside a matched handler is recorded" do
      CaptureLog.capture_log(fn ->
        crash_task(fn ->
          BodyCrashComponent.handle_event("known", %{}, %Phoenix.LiveView.Socket{})
        end)

        assert await_occurrence!().reason =~ "pick/1"
      end)
    end
  end

  describe "attach/0 and detach/0" do
    test "install and remove the handler; attach/0 is idempotent" do
      assert {:ok, config} = :logger.get_handler_config(:tymeslot_crash_reporter)
      assert config.module == CrashReporter

      assert :ok = CrashReporter.detach()

      assert :logger.get_handler_config(:tymeslot_crash_reporter) ==
               {:error, {:not_found, :tymeslot_crash_reporter}}

      assert :ok = CrashReporter.attach()
      assert :ok = CrashReporter.attach()
    end
  end

  describe "loop prevention" do
    setup do
      with_config(:error_tracker, ignorer: RaisingIgnorer)
      with_config(:tymeslot, crash_reporter_test_pid: self())
      :ok
    end

    # The crash travels through the :logger handler attach/0 installed, so the
    # production code under test is invoked by the runtime, not by this body.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "a crash whose report fails does not re-enter the handler" do
      CaptureLog.capture_log(fn ->
        crash_task(fn -> raise "boom" end)

        # The report is attempted once, and its failure produces no new crash
        # that would report again.
        assert_receive :ignorer_invoked, 2_000
        refute_receive :ignorer_invoked, 300
      end)

      assert {:ok, _config} = :logger.get_handler_config(:tymeslot_crash_reporter)
    end
  end
end
