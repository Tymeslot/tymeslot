defmodule Tymeslot.Security.FieldValidators.TLDList do
  @moduledoc """
  Valid top-level domain lookups and typo suggestions.

  Loads TLD data from `priv/tlds.json` at compile time into a MapSet
  for O(1) lookups. Excludes special-use TLDs (localhost, test, onion, etc.)
  from public validation.
  """

  @tld_json_path Path.join([__DIR__, "../../../../priv/tlds.json"])
  @external_resource @tld_json_path

  @tld_data @tld_json_path |> File.read!() |> JSON.decode!()

  @common_tlds MapSet.new(@tld_data["tlds"]["common"])

  @public_tlds @tld_data["tlds"]
               |> Map.drop(["special_use"])
               |> Map.values()
               |> List.flatten()
               |> MapSet.new()

  @doc """
  Returns `true` if the given TLD is a known public TLD, `false` otherwise.

  Special-use TLDs (localhost, test, local, onion, etc.) are excluded.
  Comparison is case-insensitive.
  """
  @spec valid_public_tld?(String.t()) :: boolean()
  def valid_public_tld?(tld) when is_binary(tld) do
    MapSet.member?(@public_tlds, String.downcase(tld))
  end

  @doc """
  Extracts the TLD from a domain string.

  For domains like "company.co.uk", checks if the last two parts form
  a known second-level TLD (e.g. "co.uk"). If so, returns that.
  Otherwise returns just the last part (e.g. "com").

  Comparison is case-insensitive; result is always lowercase.
  """
  @spec extract_tld(String.t()) :: String.t()
  def extract_tld(domain) when is_binary(domain) do
    parts = domain |> String.downcase() |> String.split(".")

    if length(parts) >= 2 do
      two_part = parts |> Enum.take(-2) |> Enum.join(".")

      if MapSet.member?(@public_tlds, two_part) do
        two_part
      else
        List.last(parts)
      end
    else
      List.last(parts)
    end
  end

  @doc """
  Suggests a valid TLD for a likely typo.

  Returns `{:ok, suggestion}` when exactly one plausible candidate is found
  within edit distance 2. Returns `:no_suggestion` when the input is already
  valid, no candidates exist within range, or the candidates are too ambiguous
  to make a confident recommendation.
  """
  @spec suggest_tld(String.t()) :: {:ok, String.t()} | :no_suggestion
  def suggest_tld(tld) when is_binary(tld) do
    tld_down = String.downcase(tld)

    if valid_public_tld?(tld_down) do
      :no_suggestion
    else
      find_suggestion(tld_down)
    end
  end

  defp find_suggestion(typo) do
    candidates =
      @public_tlds
      |> Enum.map(fn tld -> {tld, dl_distance(typo, tld), MapSet.member?(@common_tlds, tld)} end)
      |> Enum.filter(fn {_, dist, _} -> dist <= 2 end)
      |> Enum.sort_by(fn {_, dist, is_common} -> {dist, !is_common} end)

    case candidates do
      [] -> :no_suggestion
      [{best_tld, best_dist, _} | _] -> resolve_candidate(candidates, best_tld, best_dist)
    end
  end

  defp resolve_candidate(candidates, best_tld, best_dist) do
    total_at_best = Enum.count(candidates, fn {_, dist, _} -> dist == best_dist end)
    common_at_best = Enum.count(candidates, fn {_, dist, c} -> dist == best_dist and c end)

    cond do
      total_at_best == 1 -> {:ok, best_tld}
      common_at_best == 1 -> {:ok, find_common_at_dist(candidates, best_dist)}
      total_at_best <= 3 -> {:ok, best_tld}
      true -> :no_suggestion
    end
  end

  defp find_common_at_dist(candidates, dist) do
    {tld, _, _} = Enum.find(candidates, fn {_, d, common?} -> d == dist and common? end)
    tld
  end

  # Damerau-Levenshtein distance (optimal string alignment variant).
  # Counts insertions, deletions, substitutions, and adjacent transpositions
  # each as a single operation.
  defp dl_distance(s, t) do
    s_chars = String.graphemes(s)
    t_chars = String.graphemes(t)
    s_len = length(s_chars)
    t_len = length(t_chars)

    cond do
      s_len == 0 -> t_len
      t_len == 0 -> s_len
      true -> dl_matrix(s_chars, t_chars, s_len, t_len)
    end
  end

  defp dl_matrix(s_chars, t_chars, s_len, t_len) do
    initial = dl_init_matrix(s_len, t_len)

    result =
      Enum.reduce(1..s_len, initial, fn i, d ->
        Enum.reduce(1..t_len, d, fn j, d ->
          put_in(d[i][j], dl_cell(d, s_chars, t_chars, i, j))
        end)
      end)

    result[s_len][t_len]
  end

  defp dl_init_matrix(s_len, t_len) do
    for i <- 0..s_len, into: %{} do
      {i,
       for j <- 0..t_len, into: %{} do
         cond do
           i == 0 -> {j, j}
           j == 0 -> {j, i}
           true -> {j, 0}
         end
       end}
    end
  end

  defp dl_cell(d, s_chars, t_chars, i, j) do
    sc = Enum.at(s_chars, i - 1)
    tc = Enum.at(t_chars, j - 1)
    cost = if sc == tc, do: 0, else: 1

    val = min(min(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + cost)
    maybe_transposition(d, s_chars, t_chars, i, j, val)
  end

  defp maybe_transposition(d, s_chars, t_chars, i, j, val) when i > 1 and j > 1 do
    if Enum.at(s_chars, i - 1) == Enum.at(t_chars, j - 2) and
         Enum.at(s_chars, i - 2) == Enum.at(t_chars, j - 1) do
      min(val, d[i - 2][j - 2] + 1)
    else
      val
    end
  end

  defp maybe_transposition(_, _, _, _, _, val), do: val
end
