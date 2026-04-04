from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


MediaKind = Literal["image", "pdf", "folder"]


class HealthResponse(BaseModel):
    ok: bool = True
    service: str
    version: str


class TagDto(BaseModel):
    tagId: str
    name: str
    category: str


class TagInput(BaseModel):
    name: str
    category: str


class TagListResponse(BaseModel):
    items: list[TagDto]


class ItemTagsResponse(BaseModel):
    mediaId: str
    items: list[TagDto]


class ResolvedIdentityDto(BaseModel):
    mediaId: str | None = None
    aliases: list[str] = Field(default_factory=list)
    normalizedPath: str | None = None
    relativePathHint: str | None = None
    sizeBytes: int | None = None
    modifiedEpochMs: int | None = None


class AddItemTagsRequest(BaseModel):
    tags: list[TagInput] = Field(default_factory=list)
    tag: TagInput | None = None
    identity: ResolvedIdentityDto | None = None


class AddItemTagsResponse(BaseModel):
    ok: bool = True
    mediaId: str


class DeleteItemTagsRequest(BaseModel):
    tagIds: list[str] = Field(default_factory=list)


class MessageResponse(BaseModel):
    ok: bool = True
    message: str


class MediaItemDto(BaseModel):
    mediaId: str
    displayName: str
    folderRaw: str
    kind: Literal["image", "pdf"]
    fullPath: str
    sizeBytes: int | None = None
    modifiedAt: datetime | None = None
    mimeType: str | None = None
    etag: str | None = None


class SearchResponse(BaseModel):
    items: list[MediaItemDto]
    total: int
    limit: int
    offset: int


class RescanRequest(BaseModel):
    folderRaw: str | None = None


class OrganizeLibraryRequest(BaseModel):
    folderRaw: str


class OrganizeLibraryResponse(BaseModel):
    ok: bool = True
    moved: dict[str, str] = Field(default_factory=dict)
    movedCount: int = 0
    rescannedCount: int = 0


class DownloadUrlRequest(BaseModel):
    folderRaw: str
    url: str = ""
    urls: list[str] = Field(default_factory=list)
    cookieFilePath: str | None = None
    cookieMode: Literal['auto', 'none', 'project_kemono', 'project_coomer', 'project_combined', 'custom'] = 'auto'
    urlListFilePath: str | None = None
    sites: list[str] = Field(default_factory=list)
    favoritePosts: bool = False
    favoriteUserServices: list[str] = Field(default_factory=list)
    mediaType: Literal["images", "videos", "images_videos", "all"] = "all"
    parallelDownloads: int = 6
    inline: bool = False
    content: bool = False
    comments: bool = False
    saveJson: bool = False
    overwrite: bool = False
    verbose: bool = False
    convertHitomiToPdf: bool = True
    artistTag: str | None = None
    seriesTag: str | None = None
    freeTags: list[str] = Field(default_factory=list)
    characterTags: list[str] = Field(default_factory=list)
    targetCollection: str | None = None
    organizeAfterImport: bool = False


class DownloadUrlResponse(BaseModel):
    ok: bool = True
    importedCount: int
    skippedCount: int
    failedCount: int
    taggedCount: int = 0
    organizedCount: int = 0
    rescannedCount: int = 0
    targetCollection: str | None = None


class RenameSideDto(BaseModel):
    mediaId: str | None = None
    path: str | None = None
    folderRaw: str | None = None
    displayName: str | None = None
    normalizedPath: str | None = None
    relativePathHint: str | None = None
    sizeBytes: int | None = None
    modifiedEpochMs: int | None = None


class RenameRequest(BaseModel):
    oldMediaId: str | None = None
    newMediaId: str | None = None
    oldPath: str | None = None
    newPath: str | None = None
    before: RenameSideDto | None = None
    after: RenameSideDto | None = None


class DeleteItemRequest(BaseModel):
    mediaId: str | None = None
    path: str | None = None
    folderRaw: str | None = None
    displayName: str | None = None
    hardDelete: bool = False
    normalizedPath: str | None = None
    relativePathHint: str | None = None
    sizeBytes: int | None = None
    modifiedEpochMs: int | None = None


class DeleteRequest(BaseModel):
    mediaId: str | None = None
    path: str | None = None
    folderRaw: str | None = None
    displayName: str | None = None
    hardDelete: bool = False
    items: list[DeleteItemRequest] = Field(default_factory=list)


class FolderDto(BaseModel):
    folderRaw: str
    displayName: str
    lastScannedAt: datetime | None = None


class FolderListResponse(BaseModel):
    items: list[FolderDto]


class FolderEntryDto(BaseModel):
    entryId: str
    displayName: str
    folderRaw: str
    kind: MediaKind
    mediaId: str | None = None
    fullPath: str | None = None
    sizeBytes: int | None = None
    modifiedAt: datetime | None = None


class FolderChildrenResponse(BaseModel):
    items: list[FolderEntryDto]
    total: int
    limit: int
    offset: int


class MediaMetaResponse(BaseModel):
    mediaId: str
    displayName: str
    kind: Literal["image", "pdf"]
    mimeType: str | None = None
    sizeBytes: int | None = None
    modifiedAt: datetime | None = None
    etag: str | None = None
    supportsRange: bool = True
    pageCount: int | None = None


