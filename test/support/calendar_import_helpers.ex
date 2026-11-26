defmodule TymeslotWeb.CalendarImportHelpers do
  @moduledoc """
  Drives the calendar's `.ics` import in LiveView tests: opening it from
  display options, uploading a file, starting the import and waiting for
  its result.
  """

  import ExUnit.Assertions
  import Phoenix.LiveViewTest

  @endpoint TymeslotWeb.Endpoint

  # The import writes from a background task; allow for a busy test machine.
  @task_timeout 5_000

  @doc "How long to wait for the import task's messages, in milliseconds."
  @spec task_timeout() :: pos_integer()
  def task_timeout, do: @task_timeout

  @doc "Opens the import from the calendar's display options."
  @spec open_import(Phoenix.LiveViewTest.View.t()) :: String.t()
  def open_import(lv) do
    lv |> element("#calendar-display-options > button") |> render_click()
    lv |> element("#calendar-import-ics") |> render_click()
  end

  @doc """
  Uploads `content` as the `.ics` file. The file is planned in an async task
  once uploaded; `render_async/1` waits for it.
  """
  @spec upload(Phoenix.LiveViewTest.View.t(), String.t(), String.t()) :: String.t()
  def upload(lv, content, name \\ "calendar.ics") do
    lv
    |> file_input("#calendar-ics-upload", :ics_file, [
      %{name: name, content: content, type: "text/calendar"}
    ])
    |> render_upload(name)

    render_async(lv)
  end

  @doc "Starts the import of the uploaded file."
  @spec start_import(Phoenix.LiveViewTest.View.t()) :: String.t()
  def start_import(lv), do: lv |> element("#calendar-import-start") |> render_click()

  @doc """
  Renders until the import's result has reached the surface. It arrives in
  two hops, each a message to the LiveView (the task's result, then the
  surface's `send_update/2`); one render per hop lets both land, and one
  more is spare.
  """
  @spec settle(Phoenix.LiveViewTest.View.t()) :: String.t()
  def settle(lv), do: Enum.reduce(1..3, nil, fn _hop, _html -> render(lv) end)

  @doc "Waits for the import task `task` to exit."
  @spec await_task(pid()) :: true
  def await_task(task) do
    ref = Process.monitor(task)
    assert_receive {:DOWN, ^ref, :process, ^task, _reason}, @task_timeout
    true
  end
end
