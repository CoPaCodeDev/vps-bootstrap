import asyncio
import os

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..config import settings
from ..dependencies import get_current_user

router = APIRouter(prefix="/system", tags=["System"])


class UpdateResult(BaseModel):
    updated: bool
    output: str
    new_templates: list[str] = []


@router.post("/update", response_model=UpdateResult)
async def update_templates(user: str = Depends(get_current_user)):
    """Git pull im Repo-Verzeichnis ausfuehren um Templates zu aktualisieren."""
    repo_dir = os.path.dirname(settings.templates_dir)

    if not os.path.isdir(os.path.join(repo_dir, ".git")):
        raise HTTPException(
            status_code=500,
            detail=f"{repo_dir} ist kein Git-Repository",
        )

    # Templates vorher erfassen
    templates_before = set()
    tpl_dir = settings.templates_dir
    if os.path.isdir(tpl_dir):
        templates_before = {
            e for e in os.listdir(tpl_dir)
            if os.path.isdir(os.path.join(tpl_dir, e))
        }

    # git pull ausfuehren
    proc = await asyncio.create_subprocess_exec(
        "git", "pull", "--ff-only",
        cwd=repo_dir,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=30)
    output = stdout.decode().strip()

    # Templates nachher erfassen
    templates_after = set()
    if os.path.isdir(tpl_dir):
        templates_after = {
            e for e in os.listdir(tpl_dir)
            if os.path.isdir(os.path.join(tpl_dir, e))
        }

    new_templates = sorted(templates_after - templates_before)
    updated = proc.returncode == 0 and "Already up to date" not in output

    return UpdateResult(
        updated=updated,
        output=output,
        new_templates=new_templates,
    )
