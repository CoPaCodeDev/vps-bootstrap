from fastapi import Request, HTTPException


async def get_current_user(request: Request) -> str:
    """Liest den authentifizierten Benutzer aus dem Authelia Remote-User Header."""
    user = request.headers.get("Remote-User")
    if not user:
        raise HTTPException(status_code=401, detail="Nicht authentifiziert")
    return user
