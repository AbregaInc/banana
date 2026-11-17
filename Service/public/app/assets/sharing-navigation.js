// Export is a destination beside the shared data, never a control in the identity banner.
export function canViewPage(account, id) {
  if (id === 'feeds') return Boolean(account?.shared && account.dataFeedsAllowed);
  return !account?.shared || account.views.includes(id);
}
