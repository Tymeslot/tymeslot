defmodule Mix.Tasks.SetVersion do
  use Mix.Task

  alias Jason.OrderedObject

  @shortdoc "Sets the Core version and regenerates the Cloudron release files"

  @moduledoc """
  Updates the version string in the Core project files atomically, regenerates
  the plain-text Cloudron changelog, and adds a new entry to
  CloudronVersions.json.

  Releases are cut in lockstep with the SaaS repository: both repositories
  carry the same vX.Y.Z tags, and the workspace `release.sh` runs this task
  here before running the SaaS repository's own `set_version`.

  ## Usage

      mix set_version VERSION

  ## Example

      mix set_version 1.0.0

  ## Files Updated

    - `mix.exs`
    - `CloudronManifest.json`
    - `CHANGELOG` (plain-text Cloudron changelog regenerated)
    - `CloudronVersions.json` (new version entry added)
  """

  @version_files [
    {"mix.exs", ~r/version: "\d+\.\d+\.\d+"/},
    {"CloudronManifest.json", ~r/"version": "\d+\.\d+\.\d+"/}
  ]

  # Candidate locations for the curated changelog highlights, tried in order.
  # The highlights file is authored alongside the public changelog in the
  # sibling SaaS repository; in the release workspace the sibling path
  # resolves and the curated text is baked into CloudronVersions.json. A
  # standalone Core checkout has neither file and simply falls back to the
  # raw commit section.
  @highlights_paths [
    "priv/changelog_highlights.json",
    "../tymeslot-saas/priv/changelog_highlights.json"
  ]

  # Shown in the Cloudron update prompt when a release carries no Core-facing
  # changes at all (no Core commits and no curated summary), for example a
  # SaaS-only release. An empty changelog makes Cloudron treat the version as
  # having nothing to announce and it never surfaces the update, so we always
  # emit at least this line.
  @fallback_changelog "Maintenance release with behind-the-scenes improvements."

  @impl Mix.Task
  def run([version]) do
    unless Regex.match?(~r/^\d+\.\d+\.\d+$/, version) do
      Mix.raise("Invalid version format: #{inspect(version)}. Expected semver like 1.2.3")
    end

    root = File.cwd!()

    Mix.shell().info("Setting version to #{version}...\n")

    Enum.each(@version_files, fn {relative_path, pattern} ->
      path = Path.join(root, relative_path)
      original = File.read!(path)
      replacement = build_replacement(relative_path, version)
      updated = Regex.replace(pattern, original, replacement)

      if original == updated do
        Mix.shell().info("  (unchanged) #{relative_path}")
      else
        File.write!(path, updated)
        Mix.shell().info("  updated    #{relative_path}")
      end
    end)

    Mix.shell().info("\nRegenerating changelog for v#{version}...\n")
    regenerate_changelog(root, version)

    add_cloudron_version(root, version)

    Mix.shell().info("\nDone. Next steps:")
    Mix.shell().info("  git add -A && git commit -m \"chore: bump version to #{version}\"")
    Mix.shell().info("  git tag v#{version}")
  end

  def run(_args) do
    Mix.raise("Usage: mix set_version VERSION")
  end

  @doc """
  Builds the Cloudron update-modal changelog text for a release.

  Operators see this in the self-hosted update prompt, so it mirrors the public
  web changelog: `[BREAKING]` lines (always shown, parsed from the raw commit
  section) followed by the curated summary and highlights. SaaS-scoped
  highlights are dropped, since Cloudron is the Core product. When a release
  has no curated Core highlights it falls back to the raw commit section
  verbatim, which keeps the Core commit list in front of operators rather than
  replacing it with a summary written about a SaaS-only release.

  A release with no Core commits at all has no such fallback (the raw section
  is empty), so the curated summary is the only thing an operator can be told.
  Without it the update prompt would render blank.

  Public for testing; `run/1` reaches it through `cloudron_changelog_text/2`.
  """
  @spec build_cloudron_changelog(String.t(), nil | %{summary: String.t() | nil, highlights: list}) ::
          String.t()
  def build_cloudron_changelog(raw_section, nil), do: raw_section

  def build_cloudron_changelog(raw_section, %{summary: summary, highlights: highlights}) do
    core_bullets =
      highlights
      |> Enum.reject(fn {scope, _text} -> scope == "saas" end)
      |> Enum.map(fn {_scope, text} -> "* #{text}" end)

    case {core_bullets, String.trim(raw_section)} do
      {[], ""} ->
        summary || ""

      {[], _raw} ->
        raw_section

      {bullets, _raw} ->
        breaking =
          raw_section
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, "[BREAKING]"))

        (breaking ++ [summary] ++ bullets)
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n")
    end
  end

  defp add_cloudron_version(root, version) do
    versions_path = Path.join(root, "CloudronVersions.json")
    manifest_path = Path.join(root, "CloudronManifest.json")

    versions_data = versions_path |> File.read!() |> Jason.decode!()
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    changelog_text = cloudron_changelog_text(root, version)

    manifest_with_image =
      manifest
      |> Map.put("dockerImage", "luka1thb/tymeslot-cloudron:#{version}")
      |> Map.put("changelog", changelog_text)

    now = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")

    version_entry = %{
      "manifest" => manifest_with_image,
      "creationDate" => now,
      "ts" => now,
      "publishState" => "published"
    }

    existing_versions = Map.get(versions_data, "versions", %{})
    all_versions = Map.put(existing_versions, version, version_entry)

    # Encode with an explicit key order so the catalog stays readable and diffs
    # stay minimal: top-level `stable` before `versions`, and version entries
    # sorted ascending by semver (a new release simply appends at the end).
    updated_data =
      OrderedObject.new(
        stable: true,
        versions: sort_versions(all_versions)
      )

    json = Jason.encode!(updated_data, pretty: true)
    File.write!(versions_path, json <> "\n")
    Mix.shell().info("  updated    CloudronVersions.json")
  end

  @doc """
  Orders the version entries ascending by semver for a stable, readable catalog.

  Semver-aware so `0.100.0` sorts after `0.99.0` (plain string order gets this
  wrong). Returns a `Jason.OrderedObject` whose `values` preserve the order
  through encoding.

  Public for testing; `run/1` reaches it through `add_cloudron_version/2`.
  """
  @spec sort_versions(%{optional(String.t()) => map()}) :: OrderedObject.t()
  def sort_versions(versions) do
    versions
    |> Enum.sort(fn {a, _entry_a}, {b, _entry_b} -> Version.compare(a, b) != :gt end)
    |> OrderedObject.new()
  end

  defp regenerate_changelog(root, version) do
    git_cliff = System.find_executable("git-cliff") || "git-cliff"
    tag = "v#{version}"

    cloudron_path = Path.join(root, "CHANGELOG")
    cloudron_config = Path.join(root, "cliff-cloudron.toml")

    # git-cliff buckets commits into releases by their position in a
    # timestamp-sorted walk, comparing each commit's date against the tag
    # commits' dates. A rebased or cherry-picked commit whose committer date
    # predates a later release's tag is then filed under the *older* release,
    # even though it isn't an ancestor of that tag, i.e. it never shipped in
    # that release tree. To attribute every commit to the release that actually
    # contains it, we drive git-cliff over explicit `prev..tag` ranges instead:
    # a range is pure git reachability, so each release gets exactly the commits
    # its tree shipped.
    ranges = release_ranges(root, tag)

    releases =
      ranges
      |> Enum.flat_map(&range_releases(git_cliff, root, cloudron_config, &1))
      |> merge_by_version()

    context = Jason.encode!(releases, pretty: true)
    render_from_context(git_cliff, root, cloudron_config, context, cloudron_path)
    Mix.shell().info("  CHANGELOG updated")
  end

  # Release ranges, newest-first, as `{base_ref, head_ref, tag_override}`.
  #
  # The lineage comes straight from the repository's semver tags rather than
  # from a full-history git-cliff run: git-cliff's timestamp-bucketed walk
  # silently drops a release whose bucket ends up empty (its commits carry
  # rebased dates), and a dropped release here would lump its commits into the
  # neighbouring section. Every tag becomes a head, including tags that sit off
  # the current main line after history surgery: their commits are reachable
  # only through the tag, so skipping them would silently drop those releases.
  # Each head's base is the semver-previous tag; a range is pure reachability,
  # so that still yields exactly the commits the release shipped.
  defp release_ranges(root, tag) do
    all_tags = semver_tags(root)
    base_for = all_tags |> Enum.zip(tl(all_tags) ++ [:root]) |> Map.new()

    pairs = Enum.map(all_tags, &{Map.fetch!(base_for, &1), &1, nil})

    # The version being cut isn't tagged yet, so its commits are everything
    # since the latest released tag on this line (an off-line tag would make
    # the range span unrelated history). Prepend it as a `latest..HEAD` range
    # labelled with the new tag. When regenerating an already-tagged version
    # this is a no-op.
    case Enum.find(all_tags, &ancestor_of_head?(root, &1)) do
      latest when is_binary(latest) and latest != tag -> [{latest, "HEAD", tag} | pairs]
      _latest_is_tag_or_missing -> pairs
    end
  end

  # All vX.Y.Z tags, sorted newest-first by semver.
  defp semver_tags(root) do
    "git"
    |> git_output(root, ["tag", "--list", "v*"])
    |> String.split()
    |> Enum.filter(&Regex.match?(~r/^v\d+\.\d+\.\d+$/, &1))
    |> Enum.sort_by(&tag_version/1, {:desc, Version})
  end

  defp tag_version(tag), do: tag |> String.trim_leading("v") |> Version.parse!()

  defp ancestor_of_head?(root, tag) do
    {_output, code} =
      System.cmd("git", ["merge-base", "--is-ancestor", tag, "HEAD"],
        cd: root,
        env: [],
        stderr_to_stdout: true
      )

    code == 0
  end

  defp range_releases(git_cliff, root, config, {base, head, tag_override}) do
    base_ref = resolve_base(root, base)
    tag_args = if tag_override, do: ["--tag", tag_override], else: []
    args = ["--config", config] ++ tag_args ++ ["#{base_ref}..#{head}", "--context"]

    git_cliff
    |> git_output(root, args)
    |> Jason.decode!(objects: :ordered_objects)
    |> Enum.reject(&is_nil(&1["version"]))
  end

  defp resolve_base(root, :root) do
    "git"
    |> git_output(root, ["rev-list", "--max-parents=0", "HEAD"])
    |> String.split()
    |> List.last()
  end

  defp resolve_base(_root, tag), do: tag

  # A range crossing an off-line tag makes git-cliff split out an extra section
  # for it, so the same release can surface from more than one range. Merge the
  # sections per version (deduplicating the commits) and order the result
  # newest-first by semver.
  defp merge_by_version(releases) do
    releases
    |> Enum.group_by(& &1["version"])
    |> Enum.map(fn {_version, [base | _rest] = group} ->
      commits =
        group
        |> Enum.flat_map(&(&1["commits"] || []))
        |> Enum.uniq_by(&commit_identity/1)
        |> Enum.sort_by(&commit_timestamp/1, :desc)

      put_commits(base, commits)
    end)
    |> Enum.sort_by(&tag_version(&1["version"]), {:desc, Version})
  end

  defp commit_identity(commit), do: commit["raw_message"] || commit["message"]

  defp commit_timestamp(commit) do
    case commit["committer"] do
      %OrderedObject{} = committer -> committer["timestamp"] || 0
      _missing -> 0
    end
  end

  defp put_commits(%OrderedObject{values: values} = release, commits) do
    %{
      release
      | values:
          Enum.map(values, fn
            {"commits", _existing} -> {"commits", commits}
            pair -> pair
          end)
    }
  end

  defp render_from_context(git_cliff, root, config, context, out_path) do
    tmp = Path.join(System.tmp_dir!(), "tymeslot-cloudron-context.json")
    File.write!(tmp, context)
    rendered = git_output(git_cliff, root, ["--config", config, "--from-context", tmp])
    File.rm(tmp)

    # A single from-context render places the sections back to back; the file
    # has always separated them with two blank lines, so restore that (and
    # keep `parse_changelog_section/2` seeing the familiar shape).
    formatted = Regex.replace(~r/([^\n])\n\[(\d)/, rendered, "\\1\n\n\n[\\2")
    File.write!(out_path, formatted)
  end

  defp git_output(cmd, root, args) do
    case System.cmd(cmd, args, cd: root, env: [], stderr_to_stdout: false) do
      {output, 0} ->
        output

      {output, code} ->
        Mix.raise(
          "`#{cmd} #{Enum.join(args, " ")}` failed (exit #{code}): #{String.trim(output)}"
        )
    end
  end

  defp cloudron_changelog_text(root, version) do
    raw = parse_changelog_section(Path.join(root, "CHANGELOG"), version)

    raw
    |> build_cloudron_changelog(read_curated_highlights(root, version))
    |> ensure_changelog_present()
  end

  @doc """
  Guarantees a non-blank Cloudron changelog.

  Cloudron won't surface a version whose changelog is empty, so a blank one
  silently blocks the update. `build_cloudron_changelog/2` stays pure and may
  legitimately return `""` (no Core commits, no curated summary); this boundary
  substitutes `@fallback_changelog` so the catalog entry is always non-empty.

  Public for testing; `run/1` reaches it through `cloudron_changelog_text/2`.
  """
  @spec ensure_changelog_present(String.t()) :: String.t()
  def ensure_changelog_present(text) do
    case String.trim(text) do
      "" -> @fallback_changelog
      _non_empty -> text
    end
  end

  defp read_curated_highlights(root, version) do
    with {:ok, path} <- find_highlights_file(root),
         {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body),
         %{} = entry <- Map.get(data, version) do
      highlights =
        entry
        |> Map.get("highlights", [])
        |> Enum.map(fn h -> {h["scope"], h["text"]} end)

      %{summary: entry["summary"], highlights: highlights}
    else
      _no_curated_entry -> nil
    end
  end

  defp find_highlights_file(root) do
    candidates = Enum.map(@highlights_paths, &Path.expand(&1, root))

    case Enum.find(candidates, &File.exists?/1) do
      nil -> :error
      path -> {:ok, path}
    end
  end

  defp parse_changelog_section(path, version) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.drop_while(&(&1 != "[#{version}]"))
        |> Enum.drop(1)
        |> Enum.take_while(&(not String.starts_with?(&1, "[")))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      {:error, _reason} ->
        ""
    end
  end

  defp build_replacement(path, version) when binary_part(path, byte_size(path), -5) == ".json" do
    ~s("version": "#{version}")
  end

  defp build_replacement(_path, version) do
    ~s(version: "#{version}")
  end
end
