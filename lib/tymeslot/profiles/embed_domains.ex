defmodule Tymeslot.Profiles.EmbedDomains do
  @moduledoc """
  Manages the allowed embed domain whitelist on a profile.

  Handles parsing, deduplication, and validation of domain lists
  for the embed/iframe security policy.
  """

  alias Tymeslot.Profiles.ProfileSchema

  @type profile :: ProfileSchema.t()
  @type result(t) :: {:ok, t} | {:error, any()}

  @doc """
  Parses a comma-separated domain string, deduplicates against the profile's
  existing whitelist, and returns the merged list ready for persistence.
  """
  @spec add_embed_domains(profile(), String.t()) ::
          {:ok, [String.t()]} | {:error, :empty_input | {:duplicates, [String.t()]}}
  def add_embed_domains(%ProfileSchema{} = profile, domains_str) when is_binary(domains_str) do
    input_domains = parse_domain_input(domains_str)

    with :ok <- validate_non_empty_input(input_domains),
         :ok <- check_no_duplicates(input_domains, profile.allowed_embed_domains) do
      existing = normalize_existing_domains(profile.allowed_embed_domains)
      {:ok, existing ++ input_domains}
    end
  end

  @doc """
  Normalises the allowed embed domains a host submitted, as a comma-separated
  string or a list: trimmed, lower-cased, de-duplicated, with the `"none"`
  keyword dropped. An input that leaves no domain, whether empty, blank or
  only `"none"`, disables embedding and becomes `["none"]`, so a cleared
  whitelist has one representation however it was cleared.

  Validating the domains is the profile changeset's job
  (`ProfileSchema.embed_domains_changeset/2`), done once, on write.
  """
  @spec normalize(String.t() | [String.t()]) :: [String.t()]
  def normalize(domains) when is_binary(domains), do: domains |> String.split(",") |> normalize()

  def normalize(domains) when is_list(domains) do
    domains
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 in ["", "none"]))
    |> Enum.uniq()
    |> disabled_when_empty()
  end

  # --- Private helpers ---

  defp parse_domain_input(str) do
    str
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp disabled_when_empty([]), do: ["none"]
  defp disabled_when_empty(domains), do: domains

  defp validate_non_empty_input([]), do: {:error, :empty_input}
  defp validate_non_empty_input(_domains), do: :ok

  defp check_no_duplicates(input_domains, existing_domains) do
    lowered_existing =
      existing_domains
      |> normalize_existing_domains()
      |> MapSet.new(&String.downcase/1)

    duplicates = Enum.filter(input_domains, &(String.downcase(&1) in lowered_existing))

    if duplicates == [],
      do: :ok,
      else: {:error, {:duplicates, duplicates}}
  end

  defp normalize_existing_domains(["none"]), do: []
  defp normalize_existing_domains(nil), do: []
  defp normalize_existing_domains(domains), do: domains
end
