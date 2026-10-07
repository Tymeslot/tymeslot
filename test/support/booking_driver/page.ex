defmodule TymeslotWeb.BookingDriver.Page do
  @moduledoc """
  What `TymeslotWeb.BookingDriver` reads off a booking page, and how it waits
  for one: the attributes on show, the journey moments a page marks, the
  pushes of its `phx-mounted` bindings, and the LiveView's assigns, which
  only the waits read. Kept per view in the test process, the one process
  that drives the view: the moment current before the driver's last action,
  and the mounted pushes already sent.
  """

  import Phoenix.LiveViewTest

  alias Phoenix.LiveViewTest.View
  alias Tymeslot.TestHelpers.Eventually

  @wait_ms 5_000

  @doc "The values of attribute `name` on the elements matching `selector`, in page order."
  @spec attribute(View.t(), String.t(), String.t()) :: [String.t()]
  def attribute(view, selector, name),
    do: view |> render() |> Floki.parse_document!() |> Floki.attribute(selector, name)

  @doc "The first element matching `selector`, or nil."
  @spec first_node(View.t(), String.t()) :: Floki.html_node() | nil
  def first_node(view, selector),
    do: view |> render() |> Floki.parse_document!() |> Floki.find(selector) |> List.first()

  @doc "The LiveView's assigns."
  @spec assigns(View.t()) :: map()
  def assigns(view), do: :sys.get_state(view.pid).socket.assigns

  @doc "Waits until `fun` returns truthy, failing with `message` after `timeout` ms."
  @spec wait((-> term()), String.t(), pos_integer()) :: term()
  def wait(fun, message, timeout \\ @wait_ms),
    do: Eventually.eventually(fun, timeout: timeout, interval: 50, message: message)

  @doc """
  A step component relays its event to the LiveView as a message, handled
  after the click returns; a synchronous call lets the LiveView handle it
  before the page is read again.
  """
  @spec sync(View.t()) :: :ok
  def sync(view) do
    _state = :sys.get_state(view.pid)
    :ok
  end

  @doc """
  Waits for the week of slots. A week is a `start_async/3` task: it is on
  show once the week fetched is the week on screen and no fetch is running.
  A page that shows no week of slots (`week_slots` nil) has nothing to wait
  for.
  """
  @spec settle(View.t()) :: :ok
  def settle(view) do
    wait(
      fn ->
        render_async(view)
        week_settled?(assigns(view))
      end,
      "the week of slots never finished loading"
    )

    :ok
  end

  defp week_settled?(%{week_slots: nil}), do: true

  defp week_settled?(%{
         week_slots: %{},
         week_slots_start: week,
         current_week_start: week,
         week_slots_loading: false
       }),
       do: true

  defp week_settled?(_assigns), do: false

  # Mounted pushes

  @doc """
  The `push` commands of the page's `phx-mounted` bindings, as
  `{event, component id}`; other commands (a transition, a focus) are the
  browser's alone.
  """
  @spec mounted_pushes(View.t()) :: [{String.t(), integer()}]
  def mounted_pushes(view) do
    view
    |> attribute("[phx-mounted]", "phx-mounted")
    |> Enum.flat_map(&pushes/1)
  end

  defp pushes(js) do
    case Jason.decode(js) do
      {:ok, ops} when is_list(ops) ->
        for ["push", %{"event" => event, "target" => cid}] <- ops,
            is_integer(cid),
            do: {event, cid}

      _not_commands ->
        []
    end
  end

  @doc """
  The mounted pushes not yet sent. A browser runs a `phx-mounted` binding
  once, when its element enters the page: the pushes on show are remembered
  per view, and one is due again only after it has left the page and come
  back (a new element).
  """
  @spec new_mounted_pushes(View.t()) :: [{String.t(), integer()}]
  def new_mounted_pushes(view) do
    key = {__MODULE__, :mounted_pushes, view.pid}
    on_show = MapSet.new(mounted_pushes(view))
    sent = MapSet.intersection(Process.get(key, MapSet.new()), on_show)

    Process.put(key, on_show)
    MapSet.to_list(MapSet.difference(on_show, sent))
  end

  # Moments

  @doc """
  The journey moments the page marks (`data-moment`, `data-moment-state`),
  as `{moment, state}` in document order, which is journey order. A page of
  the classic journey marks none.
  """
  @spec moments(Floki.html_tree()) :: [{String.t(), String.t()}]
  def moments(doc) do
    for node <- Floki.find(doc, "[data-moment][data-moment-state]") do
      [moment] = Floki.attribute(node, "data-moment")
      [state] = Floki.attribute(node, "data-moment-state")
      {moment, state}
    end
  end

  @doc """
  Whether the page has moved on: with `last`, the moment `last` is done and
  another is current; with no `last`, a done moment comes before a current
  one.
  """
  @spec moved_on?([{String.t(), String.t()}], String.t() | nil) :: boolean()
  def moved_on?(moments, nil) do
    moments
    |> Enum.map(fn {_moment, state} -> state end)
    |> Enum.drop_while(&(&1 != "done"))
    |> Enum.member?("current")
  end

  def moved_on?(moments, last),
    do: {last, "done"} in moments and Enum.any?(moments, &match?({_moment, "current"}, &1))

  @doc """
  Remembers the moment current now, so that `BookingDriver.continue/1` can
  tell a page that moved on by itself from one still where it was.
  """
  @spec remember(View.t()) :: :ok
  def remember(view) do
    current =
      view
      |> render()
      |> Floki.parse_document!()
      |> moments()
      |> Enum.find_value(fn {moment, state} -> if state == "current", do: moment end)

    Process.put({__MODULE__, :last_moment, view.pid}, current)
    :ok
  end

  @doc "The moment `remember/1` last kept for `view`, or nil."
  @spec last_moment(View.t()) :: String.t() | nil
  def last_moment(view), do: Process.get({__MODULE__, :last_moment, view.pid})
end
