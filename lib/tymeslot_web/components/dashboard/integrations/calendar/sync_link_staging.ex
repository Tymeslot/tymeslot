defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkStaging do
  @moduledoc """
  The grid's unsaved edits: what the organiser has clicked, against what is
  stored, and the desired grid the two produce together.

  Pure functions over two maps, with no socket and no `Repo` — which is the
  point of the split. Staging is the one piece of the sync-link panel that has
  a real model behind it rather than a rendering or a write, and holding that
  model here keeps its three rules stated once, where they can be read
  together:

  - **A click that returns a cell to its stored state is not a change.** The
    cycle is three states long, so clicking a cell three times lands back where
    it began. A staging map that recorded the click rather than the difference
    would count a pending change over a grid identical to the stored one, and
    the organiser would press save to apply nothing.

  - **`:off` is staged, but never sent.** The grid needs to draw a cell the
    organiser has cleared, so the intention is held; `apply_matrix/2` reads
    deletion as *absence* from the map, so the intention is dropped on the way
    out. Carrying `:off` through would name a pair the write path then had to
    interpret, and interpreting it as anything but a delete is a bug.

  - **The save sends the whole desired grid, not the edits.** `apply_matrix/2`
    diffs what it is given against what is stored and deletes whatever is
    missing, so handing it only the staged cells would read as "remove every
    link the organiser did not touch this sitting".
  """

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkMatrix

  @type pair :: {integer(), integer()}
  @type state :: :active | :paused | :off
  @type staged :: %{pair() => state()}

  @doc """
  Records one click, or forgets it where it undoes itself.
  """
  @spec stage(staged(), [map()], pair(), state()) :: staged()
  def stage(staged, links, pair, state) do
    stored = SyncLinkMatrix.stored_cells(links)

    if Map.get(stored, pair) == normalise(state) do
      Map.delete(staged, pair)
    else
      Map.put(staged, pair, state)
    end
  end

  @doc """
  The grid a save will ask for: the stored links with the staged clicks laid
  over them, and the cleared cells dropped.
  """
  @spec desired(staged(), [map()]) :: %{pair() => :active | :paused}
  def desired(staged, links) do
    links
    |> SyncLinkMatrix.stored_cells()
    |> Map.merge(staged)
    |> Map.reject(fn {_pair, state} -> state == :off end)
  end

  @doc """
  Reads the ids off a cell click, refusing anything that cannot be a pair.

  A self-link is refused here as well as by the check constraint: the grid
  never draws that cell, so an id naming one arrived forged, and staging it
  would show the organiser a cell the save is certain to reject.
  """
  @spec cell_pair(map(), (term() -> integer() | nil)) :: {:ok, pair()} | :error
  def cell_pair(%{"source" => source, "target" => target}, cast_id) do
    case {cast_id.(source), cast_id.(target)} do
      {nil, _target} -> :error
      {_source, nil} -> :error
      {same, same} -> :error
      {source_id, target_id} -> {:ok, {source_id, target_id}}
    end
  end

  def cell_pair(_params, _cast_id), do: :error

  @doc """
  Casts a state that arrived off the wire, refusing anything unrecognised.

  `:error` rather than a default, because every plausible default is wrong: a
  forged value must not be able to delete a link, and must not silently
  activate one either.
  """
  @spec cast_state(term()) :: {:ok, state()} | :error
  def cast_state(raw) do
    case SyncLinkMatrix.cast_state(raw) do
      nil -> :error
      state -> {:ok, state}
    end
  end

  # An absent cell and a cell staged `:off` mean the same thing to the stored
  # map, which records only links that exist.
  defp normalise(:off), do: nil
  defp normalise(state), do: state
end
