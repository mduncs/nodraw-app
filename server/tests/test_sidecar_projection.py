"""Projection bases and cleared values match the app's frontmatter parser."""
import pytest

from sidecar_projection import parse_sidecar, project, read_base


def test_description_note_can_be_edited_against_parser_base(tmp_path):
    sidecar = tmp_path / "capture.md"
    sidecar.write_text('---\ndescription: captured description\n---\nBody\n')
    project(sidecar, {"notes": "edited note"}, {"notes": ["captured description"]})
    assert read_base(sidecar)["notes"] == "edited note"
    assert parse_sidecar(sidecar.read_text())[3]["description"] == "captured description"


def test_comma_separated_tags_can_be_edited_against_parser_base(tmp_path):
    sidecar = tmp_path / "capture.md"
    sidecar.write_text('---\ntags: " art, , reference "\n---\nBody\n')
    project(sidecar, {"tags": ["new"]}, {"tags": [["art", "reference"]]})
    assert read_base(sidecar)["tags"] == ["new"]


def test_cleared_note_masks_description_and_preserves_provenance(tmp_path):
    sidecar = tmp_path / "capture.md"
    sidecar.write_text('---\nnotes: edited note\ndescription: captured description\n---\nBody\n')
    project(sidecar, {"notes": ""}, {"notes": ["edited note"]})
    values = parse_sidecar(sidecar.read_text())[3]
    assert values["notes"] == ""
    assert values["description"] == "captured description"
    assert read_base(sidecar)["notes"] == ""


@pytest.mark.parametrize("header", ["notes: edited note\n", ""])
def test_cleared_note_without_description_removes_key(tmp_path, header):
    sidecar = tmp_path / "capture.md"
    sidecar.write_text(f"---\n{header}---\nBody\n")
    project(sidecar, {"notes": ""}, {"notes": ["edited note", ""]})
    assert "notes" not in parse_sidecar(sidecar.read_text())[3]
    assert read_base(sidecar)["notes"] == ""


@pytest.mark.parametrize("header, expected", [
    ('description: captured description\n', {"tags": [], "notes": "captured description"}),
    ('notes: ""\ndescription: captured description\n', {"tags": [], "notes": ""}),
    ('notes: null\ndescription: captured description\n', {"tags": [], "notes": "captured description"}),
    ('tags: " art, , reference "\n', {"tags": ["art", "reference"], "notes": ""}),
    ('tags: [" art ", ""]\n', {"tags": ["art", ""], "notes": ""}),
    ('tags: ["\\n art \\n", "\\t\\u00a0reference\\u00a0\\t"]\n', {"tags": ["\n art \n", "reference"], "notes": ""}),
    ('tags: "\\n art \\n, \\t\\u00a0reference\\u00a0\\t"\n', {"tags": ["\n art \n", "reference"], "notes": ""}),
    ('tags: [art, 1]\nnotes: 1\ndescription: captured description\n', {"tags": [], "notes": "captured description"}),
])
def test_read_base_matches_parser_values(tmp_path, header, expected):
    sidecar = tmp_path / "capture.md"
    sidecar.write_text(f"---\n{header}---\nBody\n")
    assert read_base(sidecar) == expected
