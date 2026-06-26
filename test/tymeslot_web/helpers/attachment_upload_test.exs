defmodule TymeslotWeb.Helpers.AttachmentUploadTest do
  # Overrides the global :upload_directory app env, so it cannot run async.
  use ExUnit.Case, async: false

  @moduletag :utils

  alias TymeslotWeb.Helpers.AttachmentUpload

  setup %{tmp_dir: tmp_dir} do
    original = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, tmp_dir)
    on_exit(fn -> Application.put_env(:tymeslot, :upload_directory, original) end)
    :ok
  end

  defp temp_source(tmp_dir, name, contents \\ "data") do
    path = Path.join(tmp_dir, name)
    File.write!(path, contents)
    path
  end

  @tag :tmp_dir
  test "stores a valid attachment and returns metadata", %{tmp_dir: tmp_dir} do
    source = temp_source(tmp_dir, "source.pdf", "hello")

    assert {:ok, metadata} =
             AttachmentUpload.store(7, 42, %{path: source, client_name: "Agenda v1.pdf"})

    # Filenames are sanitised (spaces → underscores) for safe storage/display.
    assert %{
             "filename" => "Agenda_v1.pdf",
             "content_type" => "application/pdf",
             "byte_size" => 5
           } = metadata

    assert String.starts_with?(metadata["stored_path"], "attachments/7/42/")
    assert File.exists?(Path.join(tmp_dir, metadata["stored_path"]))
  end

  @tag :tmp_dir
  test "rejects disallowed extensions", %{tmp_dir: tmp_dir} do
    source = temp_source(tmp_dir, "evil.exe")

    assert {:error, :unsupported_file_type} =
             AttachmentUpload.store(1, 1, %{path: source, client_name: "evil.exe"})
  end

  @tag :tmp_dir
  test "delete/1 removes a stored file", %{tmp_dir: tmp_dir} do
    source = temp_source(tmp_dir, "source.pdf")
    {:ok, metadata} = AttachmentUpload.store(1, 1, %{path: source, client_name: "doc.pdf"})
    stored = Path.join(tmp_dir, metadata["stored_path"])
    assert File.exists?(stored)

    assert :ok = AttachmentUpload.delete(metadata["stored_path"])
    refute File.exists?(stored)
  end
end
