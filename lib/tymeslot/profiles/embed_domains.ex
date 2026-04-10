defmodule Tymeslot.Profiles.EmbedDomains do
  @moduledoc """
  Manages the allowed embed domain whitelist on a profile.

  Handles parsing, deduplication, and validation of domain lists
  for the embed/iframe security policy.
  """

  alias Ecto.Changeset
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
  Validates and normalizes the allowed embed domains for a profile.

  Returns `{:ok, attrs}` where `attrs` is a map ready to be passed to
  `Profiles.update_profile/2`, or `{:error, changeset}` on validation failure.
  """
  @spec validate_and_normalize(profile(), String.t() | [String.t()]) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def validate_and_normalize(%ProfileSchema{} = profile, domains) when is_binary(domains) do
    domain_list =
      domains
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # If the user explicitly cleared the field or entered "none", we treat it as disabled.
    # We allow "none" as a literal string here to support the "Disable" button flow.
    domain_list = if domain_list == [], do: ["none"], else: domain_list
    validate_and_normalize(profile, domain_list)
  end

  def validate_and_normalize(%ProfileSchema{} = profile, domains) when is_list(domains) do
    # If the only domain is "none", we skip normalization to preserve the keyword.
    if domains == ["none"] do
      {:ok, %{allowed_embed_domains: ["none"]}}
    else
      case Security.validate_domains(domains) do
        {:ok, validated} ->
          normalized = validated |> Enum.reject(&(&1 == "none")) |> Enum.uniq()
          {:ok, %{allowed_embed_domains: normalized}}

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
end
