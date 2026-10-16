defmodule TymeslotWeb.Themes.Shared.Journey.FactTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket

  # A fact no shipped journey has, written with only the required callbacks:
  # everything else comes from `use Fact`.
  defmodule NoteFact do
    @moduledoc false
    use TymeslotWeb.Themes.Shared.Journey.Fact

    import Phoenix.Component, only: [assign: 3]

    alias TymeslotWeb.Themes.Shared.Journey.Fact

    @impl Fact
    def key, do: :note

    @impl Fact
    def requires(_assigns), do: [:meeting_type]

    @impl Fact
    def required?(_assigns), do: false

    @impl Fact
    def known?(assigns), do: is_binary(assigns[:note])

    @impl Fact
    def events, do: [:write_note]

    @impl Fact
    def handle(socket, :write_note, text), do: {:noreply, assign(socket, :note, text)}
  end

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}

  test "showing a moment that collects the fact sets nothing up by default" do
    socket = socket(%{})

    assert NoteFact.enter(socket, %{"date" => "2027-01-05"}) == socket
  end

  test "continue is done once the fact is known, and incomplete before" do
    known = socket(%{note: "Bring the floor plan"})

    assert NoteFact.continue(known) == {:done, known}
    assert NoteFact.continue(socket(%{})) == {:error, :incomplete}
  end

  test "back leaves the moment, and a moment collecting the fact may be revisited" do
    socket = socket(%{})

    assert NoteFact.back(socket) == {:leave, socket}
    assert NoteFact.revisitable?(%{})
  end

  test "a fact offers no default strategy unless it says so" do
    assert NoteFact.default_strategies() == []
  end

  test "the fact's own events reach its handle/3" do
    assert {:noreply, socket} = NoteFact.handle(socket(%{}), :write_note, "Hello")
    assert NoteFact.known?(socket.assigns)
  end
end
