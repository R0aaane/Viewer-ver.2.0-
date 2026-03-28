from __future__ import annotations

from fastapi import HTTPException, status


class ApiError(HTTPException):
    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(status_code=status_code, detail=detail)


def bad_request(message: str) -> ApiError:
    return ApiError(status.HTTP_400_BAD_REQUEST, message)


def unauthorized(message: str = '認証に失敗しました') -> ApiError:
    return ApiError(status.HTTP_401_UNAUTHORIZED, message)


def forbidden(message: str = 'アクセスが許可されていません') -> ApiError:
    return ApiError(status.HTTP_403_FORBIDDEN, message)


def not_found(message: str = '対象が見つかりません') -> ApiError:
    return ApiError(status.HTTP_404_NOT_FOUND, message)


def gone(message: str = '対象は削除済みです') -> ApiError:
    return ApiError(status.HTTP_410_GONE, message)


def server_error(message: str = 'サーバー内部でエラーが発生しました') -> ApiError:
    return ApiError(status.HTTP_500_INTERNAL_SERVER_ERROR, message)
