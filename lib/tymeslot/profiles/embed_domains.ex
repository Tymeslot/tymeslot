defmodule Tymeslot.Profiles.EmbedDomains do
  @moduledoc """
  Manages the allowed embed domain whitelist on a profile.

  Handles parsing, deduplication, and validation of domain lists
  for the embed/iframe security policy.
  """

  alias Ecto.Changeset
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Security.Security

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
  Updates the allowed embed domains for a profile.
  """
  @spec update_allowed_embed_domains(profile(), String.t() | [String.t()]) :: result(profile())
  def update_allowed_embed_domains(%ProfileSchema{} = profile, domains) when is_binary(domains) do
    domain_list =
      domains
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # If the user explicitly cleared the field or entered "none", we treat it as disabled.
    # We allow "none" as a literal string here to support the "Disable" button flow.
    domain_list = if domain_list == [], do: ["none"], else: domain_list
    update_allowed_embed_domains(profile, domain_list)
  end

  def update_allowed_embed_domains(%ProfileSchema{} = profile, domains) when is_list(domains) do
    # If the only domain is "none", we skip normalization to preserve the keyword.
    if domains == ["none"] do
      update_profile(profile, %{allowed_embed_domains: ["none"]})
    else
      case Security.validate_domains(domains) do
        {:ok, validated} ->
          normalized = validated |> Enum.reject(&(&1 == "none")) |> Enum.uniq()
          update_profile(profile, %{allowed_embed_domains: normalized})

        {:error, error_msg} ->
          changeset =
            profile
            |> Changeset.change()
            |> Changeset.add_error(:allowed_embed_domains, error_msg)

          {:error, changeset}
      end
    end
  end

  # --- Private helpers ---

  defp parse_domain_input(str) do
    str
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

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

  defp update_profile(profile, attrs) do
    ProfileQueries.update_profile(profile, attrs)
  end
end
