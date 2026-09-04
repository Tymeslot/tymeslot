defmodule Tymeslot.Integrations.Providers.Families do
  @moduledoc """
  The provider-family vocabulary, shared by every integration domain.

  A *family* answers "how does this provider connect?" — the question the
  picker groups by, and the one the `oauth_provider?/1`-style predicates ask.
  The vocabulary lives here so the system has exactly one list of families;
  membership lives in each domain's `ProviderConfig`, because the calendar and
  video domains have disjoint provider sets. One concept, one table per domain.

  ## Adding a family

  Add it to `@families`, in the position the picker should render it. Everything
  that enumerates families derives from `all/0`, and anything that must say
  something per family — `TymeslotWeb.Dashboard.CalendarSettings.ProviderPicker`
  and its group labels — fails to compile until it does. A family therefore
  cannot be half-added, which is the failure this module exists to prevent:
  before it, a family the picker did not enumerate made its providers vanish
  from the modal with no error.

  ## Declaring membership

  Each domain's `ProviderConfig` declares one table and derives its lists,
  string lists and predicates from it:

      @provider_families %{oauth: [:google, :outlook], caldav: [...], other: [...]}
      @family_index Families.build_index(@provider_families, @providers ++ @dev_only_providers)

  `build_index/2` is a compile-time check as much as a lookup table: it refuses
  an unknown family name, a provider filed under two families, and any drift
  between the table and the domain's provider list. Adding a provider is then
  one edit, and forgetting to file it is a build failure.
  """

  # Ordered as the calendar picker renders them. `:other` is the catch-all, so
  # it sorts last rather than above a named group.
  @families [:oauth, :caldav, :ews, :subscription, :other]

  @typedoc """
  How a provider connects, for grouping in the picker. `oauth` alone cannot
  answer this: a CalDAV server and a subscribed feed are both "not OAuth" but
  belong under different headings, and filing a feed under "CalDAV servers"
  tells the user something untrue about what it is.
  """
  @type t :: :oauth | :caldav | :ews | :subscription | :other

  @typedoc "A domain's declaration of which of its providers belong to which family."
  @type table :: %{t() => [atom()]}

  @typedoc "Lookup built by `build_index/2`, keyed by both provider forms."
  @type index :: %{(atom() | String.t()) => t()}

  @doc """
  The family vocabulary, in the order the picker renders it.
  """
  @spec all() :: [t()]
  def all, do: @families

  @doc """
  The providers a table files under `family`, in declaration order.
  """
  @spec members(table(), t()) :: [atom()]
  def members(table, family), do: Map.get(table, family, [])

  @doc """
  The providers a table files under `family`, as strings, for matching against
  database values such as `integration.provider`.
  """
  @spec member_strings(table(), t()) :: [String.t()]
  def member_strings(table, family) do
    table |> members(family) |> Enum.map(&Atom.to_string/1)
  end

  @doc """
  Builds the lookup behind a domain's family predicates.

  Every provider is keyed by both its atom and its string form, so the two
  can never answer differently: `caldav_based?(:caldav)` and
  `caldav_based?("caldav")` read the same entry.

  Raises at compile time if the table names a family outside the vocabulary,
  files a provider under two families, omits a provider the domain declares,
  or files one the domain does not have.
  """
  @spec build_index(table(), [atom()]) :: index()
  def build_index(table, known_providers) do
    validate_vocabulary!(table)
    validate_membership!(table, known_providers)

    for {family, providers} <- table,
        provider <- providers,
        entry <- [{provider, family}, {Atom.to_string(provider), family}],
        into: %{},
        do: entry
  end

  @doc """
  Looks a provider up in an index built by `build_index/2`.

  Answers `:other` for anything the index does not know, which is the same
  answer it gives a provider explicitly filed as `:other`: an unrecognised
  provider connects by no mechanism the UI can name either.
  """
  @spec of(index(), atom() | String.t() | any()) :: t()
  def of(index, provider), do: Map.get(index, provider, :other)

  defp validate_vocabulary!(table) do
    case Map.keys(table) -- @families do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown provider families #{inspect(unknown)}; the vocabulary is " <>
                "#{inspect(@families)} and lives in #{inspect(__MODULE__)}"
    end
  end

  defp validate_membership!(table, known_providers) do
    filed = Enum.flat_map(@families, &members(table, &1))

    candidates = [
      {"filed under more than one family", filed -- Enum.uniq(filed)},
      {"missing from the family table", known_providers -- filed},
      {"in the family table but not a provider of this domain", filed -- known_providers}
    ]

    case Enum.reject(candidates, fn {_reason, providers} -> providers == [] end) do
      [] -> :ok
      problems -> raise ArgumentError, describe(problems)
    end
  end

  defp describe(problems) do
    detail =
      Enum.map_join(problems, "; ", fn {reason, providers} ->
        "#{inspect(providers)} #{reason}"
      end)

    "provider family table disagrees with the domain's provider list: " <> detail
  end
end
