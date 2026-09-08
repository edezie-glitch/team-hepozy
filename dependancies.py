from fastapi import Header, HTTPException
from utils.security import decode_token
from jose import JWTError


def get_current_user(authorization: str = Header(...)) -> dict:
    """
    Expects:  Authorization: Bearer <token>
    Returns the decoded token payload  {sub, username}
    """
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid token")

    token = authorization.split(" ", 1)[1]

    try:
        payload = decode_token(token)
        return payload
    except JWTError:
        raise HTTPException(status_code=401, detail="Token invalid or expired")