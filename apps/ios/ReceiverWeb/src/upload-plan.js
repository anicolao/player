export function buildUploadPlan(selection, offsets = []) {
  return selection.flatMap((item, index) => {
    const offset = Number.isFinite(offsets[index]) ? offsets[index] : 0;
    if (!Number.isInteger(offset) || offset < 0 || offset > item.file.size) {
      throw new Error(`Bookshelf reported an invalid resume point for ${item.file.name}.`);
    }
    if (offset === item.file.size) return [];
    return [{ index, item, offset, body: item.file.slice(offset) }];
  });
}

export function canResumeImport(status, selection) {
  return status?.state === 'receiving'
    && Array.isArray(status.fileOffsets)
    && status.fileOffsets.length === selection.length
    && status.fileOffsets.every((offset, index) => Number.isInteger(offset)
      && offset >= 0
      && offset <= selection[index].file.size);
}
