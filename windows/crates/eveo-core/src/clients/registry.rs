// SPDX-License-Identifier: GPL-3.0-or-later
//
// 客户端登记，对应 macOS 的 Clients/ClientRegistry.swift（架构文档 5.3 节）。
// 保存上一轮的客户端列表，按窗口 ID 与新一轮的主窗口比较，得出新增、移除、改名、更新 4 类差异。

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};

use crate::model::{ClientChange, EveClient, Pid, RegistryDiff, WindowId, WindowInfo};

/// 已发现客户端的登记表。
#[derive(Debug, Clone, Default)]
pub struct ClientRegistry {
    /// 当前的客户端，按首次发现的顺序；改名与更新不改变位置。
    clients: Vec<EveClient>,
}

impl ClientRegistry {
    /// 建一个空的登记表。
    pub fn new() -> Self {
        Self::default()
    }

    /// 当前的客户端，按首次发现的顺序。
    pub fn clients(&self) -> &[EveClient] {
        &self.clients
    }

    /// 用新一轮的主窗口更新登记表，返回差异。
    ///
    /// - 新 ID 进 `added`，追加到末尾，按输入顺序。
    /// - 消失的 ID 进 `removed`，按原登记顺序。
    /// - 同一 ID 的身份变了进 `renamed`；身份没变、其他字段变了进 `updated`；都没变的不记。
    /// - 窗口 ID 被另一个 PID 复用时，视为旧客户端移除、新客户端新增，新客户端排到末尾。
    ///
    /// `main_windows` 是 [`crate::clients::selector::main_windows`] 的结果；同一 ID 出现多次时只取第一个。
    pub fn update(&mut self, main_windows: &[WindowInfo]) -> RegistryDiff {
        let mut incoming: HashMap<WindowId, EveClient> = HashMap::new();
        let mut incoming_order: Vec<WindowId> = Vec::new();
        for window in main_windows {
            if let Entry::Vacant(slot) = incoming.entry(window.window_id) {
                slot.insert(EveClient::from_window(window));
                incoming_order.push(window.window_id);
            }
        }

        let mut diff = RegistryDiff::default();
        let mut kept: Vec<EveClient> = Vec::with_capacity(incoming_order.len());
        let mut kept_ids: HashSet<WindowId> = HashSet::new();
        for old in self.clients.drain(..) {
            // 窗口不在了，或 ID 被别的进程复用：都按移除处理。
            let new = match incoming.get(&old.id) {
                Some(new) if new.pid == old.pid => new.clone(),
                _ => {
                    diff.removed.push(old);
                    continue;
                }
            };
            if new.identity != old.identity {
                diff.renamed.push(ClientChange {
                    before: old,
                    after: new.clone(),
                });
            } else if new != old {
                diff.updated.push(ClientChange {
                    before: old,
                    after: new.clone(),
                });
            }
            kept_ids.insert(new.id);
            kept.push(new);
        }
        for id in incoming_order {
            if kept_ids.contains(&id) {
                continue;
            }
            if let Some(client) = incoming.remove(&id) {
                diff.added.push(client.clone());
                kept.push(client);
            }
        }
        self.clients = kept;
        diff
    }

    /// 按窗口 ID 查找客户端。
    pub fn client_with_id(&self, id: WindowId) -> Option<&EveClient> {
        self.clients.iter().find(|c| c.id == id)
    }

    /// 按 PID 查找客户端。每个进程只有一个主窗口，所以至多一个。
    pub fn client_with_pid(&self, pid: Pid) -> Option<&EveClient> {
        self.clients.iter().find(|c| c.pid == pid)
    }

    /// 按角色名查找客户端（区分大小写）。同名的多个客户端取首次发现的那个。
    pub fn client_named(&self, name: &str) -> Option<&EveClient> {
        self.clients.iter().find(|c| c.character_name() == Some(name))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::ScreenRect;
    use crate::model::ClientIdentity;

    /// 造一个在屏、未最小化的主窗口。
    fn window(id: u64, pid: Pid, title: Option<&str>, x: f64) -> WindowInfo {
        WindowInfo {
            window_id: WindowId(id),
            pid,
            title: title.map(str::to_owned),
            frame: ScreenRect::new(x, 0.0, 1728.0, 1018.0),
            is_on_screen: true,
            is_minimized: Some(false),
            is_full_screen: None,
        }
    }

    /// 第一轮全部新增，按输入顺序。
    #[test]
    fn first_round_adds_in_input_order() {
        let mut registry = ClientRegistry::new();
        let diff = registry.update(&[
            window(2, 20, Some("EVE - B"), 0.0),
            window(1, 10, Some("EVE"), 0.0),
        ]);
        let added: Vec<_> = diff.added.iter().map(|c| c.id).collect();
        assert_eq!(added, vec![WindowId(2), WindowId(1)]);
        assert!(diff.removed.is_empty() && diff.renamed.is_empty() && diff.updated.is_empty());
        assert_eq!(registry.client_named("B").map(|c| c.pid), Some(20));
        assert_eq!(
            registry.client_with_pid(10).map(|c| c.identity.clone()),
            Some(ClientIdentity::Login)
        );
    }

    /// 登录后改名、移动后更新、消失后移除、没变的不记；顺序保持首次发现的顺序。
    #[test]
    fn classifies_changes_and_keeps_order() {
        let mut registry = ClientRegistry::new();
        registry.update(&[
            window(1, 10, Some("EVE"), 0.0),
            window(2, 20, Some("EVE - B"), 0.0),
            window(3, 30, Some("EVE - C"), 0.0),
        ]);
        let diff = registry.update(&[
            window(4, 40, Some("EVE - D"), 0.0),
            window(2, 20, Some("EVE - B"), 50.0),
            window(1, 10, Some("EVE - A"), 0.0),
        ]);
        assert_eq!(diff.renamed.len(), 1);
        assert_eq!(diff.renamed[0].after.character_name(), Some("A"));
        assert_eq!(diff.updated.len(), 1);
        assert_eq!(diff.updated[0].after.window_frame.x, 50.0);
        assert_eq!(
            diff.removed.iter().map(|c| c.id).collect::<Vec<_>>(),
            vec![WindowId(3)]
        );
        assert_eq!(
            diff.added.iter().map(|c| c.id).collect::<Vec<_>>(),
            vec![WindowId(4)]
        );
        let order: Vec<_> = registry.clients().iter().map(|c| c.id.0).collect();
        assert_eq!(order, vec![1, 2, 4]);
        assert!(
            registry
                .update(&[
                    window(4, 40, Some("EVE - D"), 0.0),
                    window(2, 20, Some("EVE - B"), 50.0),
                    window(1, 10, Some("EVE - A"), 0.0),
                ])
                .is_empty()
        );
    }

    /// 窗口 ID 被另一个进程复用：旧的移除，新的排到末尾。
    #[test]
    fn reused_id_is_remove_plus_add() {
        let mut registry = ClientRegistry::new();
        registry.update(&[
            window(1, 10, Some("EVE - A"), 0.0),
            window(2, 20, Some("EVE - B"), 0.0),
        ]);
        let diff = registry.update(&[
            window(1, 99, Some("EVE - Z"), 0.0),
            window(2, 20, Some("EVE - B"), 0.0),
        ]);
        assert_eq!(diff.removed.len(), 1);
        assert_eq!(diff.added.len(), 1);
        assert_eq!(diff.added[0].pid, 99);
        let order: Vec<_> = registry.clients().iter().map(|c| c.pid).collect();
        assert_eq!(order, vec![20, 99]);
    }

    /// 同一 ID 出现多次时只取第一个。
    #[test]
    fn duplicate_ids_take_first() {
        let mut registry = ClientRegistry::new();
        let diff = registry.update(&[
            window(1, 10, Some("EVE - A"), 0.0),
            window(1, 10, Some("EVE - X"), 0.0),
        ]);
        assert_eq!(diff.added.len(), 1);
        assert_eq!(
            registry
                .client_with_id(WindowId(1))
                .and_then(|c| c.character_name()),
            Some("A")
        );
    }
}
