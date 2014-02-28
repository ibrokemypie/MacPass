//
//  MPDocument.m
//  MacPass
//
//  Created by Michael Starke on 08.05.13.
//  Copyright (c) 2013 HicknHack Software GmbH. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "MPDocument.h"
#import "MPDocument+Search.h"
#import "MPAppDelegate.h"
#import "MPDocumentWindowController.h"
#import "MPDatabaseVersion.h"
#import "MPIconHelper.h"
#import "MPActionHelper.h"
#import "MPSettingsHelper.h"
#import "MPNotifications.h"
#import "MPConstants.h"
#import "MPSavePanelAccessoryViewController.h"

#import "DDXMLNode.h"

#import "KPKEntry.h"
#import "KPKGroup.h"
#import "KPKTree.h"
#import "KPKTree+Serializing.h"
#import "KPKCompositeKey.h"
#import "KPKMetaData.h"
#import "KPKTimeInfo.h"
#import "KPKAttribute.h"

NSString *const MPDocumentDidAddGroupNotification         = @"com.hicknhack.macpass.MPDocumentDidAddGroupNotification";
NSString *const MPDocumentDidRevertNotifiation            = @"com.hicknhack.macpass.MPDocumentDidRevertNotifiation";

NSString *const MPDocumentDidLockDatabaseNotification     = @"com.hicknhack.macpass.MPDocumentDidLockDatabaseNotification";
NSString *const MPDocumentDidUnlockDatabaseNotification   = @"com.hicknhack.macpass.MPDocumentDidUnlockDatabaseNotification";

NSString *const MPDocumentCurrentItemChangedNotification  = @"com.hicknhack.macpass.MPDocumentCurrentItemChangedNotification";

NSString *const MPDocumentEntryKey                        = @"MPDocumentEntryKey";
NSString *const MPDocumentGroupKey                        = @"MPDocumentGroupKey";

@interface MPDocument () {
@private
  BOOL _didLockFile;
  NSData *_encryptedData;
}

@property (strong, nonatomic) MPSavePanelAccessoryViewController *savePanelViewController;

@property (strong, nonatomic) KPKTree *tree;
@property (weak, nonatomic) KPKGroup *root;
@property (nonatomic, strong) KPKCompositeKey *compositeKey;

@property (assign) BOOL readOnly;
@property (strong) NSURL *lockFileURL;

@property (strong) IBOutlet NSView *warningView;
@property (weak) IBOutlet NSImageView *warningViewImage;

@end


@implementation MPDocument

+ (NSSet *)keyPathsForValuesAffectingRoot {
  return [NSSet setWithObject:@"tree"];
}

+ (KPKVersion)versionForFileType:(NSString *)fileType {
  if( NSOrderedSame == [fileType compare:MPLegacyDocumentUTI options:NSCaseInsensitiveSearch]) {
    return KPKLegacyVersion;
  }
  if( NSOrderedSame == [fileType compare:MPXMLDocumentUTI options:NSCaseInsensitiveSearch]) {
    return KPKXmlVersion;
  }
  return KPKUnknownVersion;
}

+ (NSString *)fileTypeForVersion:(KPKVersion)version {
  switch(version) {
    case KPKLegacyVersion:
      return MPLegacyDocumentUTI;
      
    case KPKXmlVersion:
      return MPXMLDocumentUTI;
      
    default:
      return @"Unknown";
  }
}

+ (BOOL)autosavesInPlace {
  return NO;
}

- (id)init {
  self = [super init];
  if(self) {
    _encryptedData = nil;
    _didLockFile = NO;
    _readOnly = NO;
    _activeFlags = MPEntrySearchTitles;
    _hasSearch = NO;
    self.tree = [KPKTree templateTree];
  }
  return self;
}

- (void)dealloc {
  [self _cleanupLock];
}

- (void)makeWindowControllers {
  MPDocumentWindowController *windowController = [[MPDocumentWindowController alloc] init];
  [self addWindowController:windowController];
}

- (void)windowControllerDidLoadNib:(NSWindowController *)aController
{
  [super windowControllerDidLoadNib:aController];
}

- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError {
  if(!self.compositeKey.hasPasswordOrKeyFile) {
    return NO; // No password or key. No save possible
  }
  NSString *fileType = [self fileTypeFromLastRunSavePanel];
  KPKVersion version = [[self class] versionForFileType:fileType];
  if(version == KPKUnknownVersion) {
    if(outError != NULL) {
      *outError = [NSError errorWithDomain:MPErrorDomain code:0 userInfo:nil];
    }
    return NO;
  }
  NSData *treeData = [self.tree encryptWithPassword:self.compositeKey forVersion:version error:outError];
  if(![treeData writeToURL:url options:0 error:outError]) {
    NSLog(@"%@", [*outError localizedDescription]);
    return NO;
  }
  return YES;
}

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError {
  /* FIXME: Lockfile handling
   self.lockFileURL = [url URLByAppendingPathExtension:@"lock"];
   if([[NSFileManager defaultManager] fileExistsAtPath:[_lockFileURL path]]) {
   self.readOnly = YES;
   }
   else {
   [[NSFileManager defaultManager] createFileAtPath:[_lockFileURL path] contents:nil attributes:nil];
   _didLockFile = YES;
   self.readOnly = NO;
   }
   */
  /*
   Delete our old Tree, and just grab the data
   */
  self.tree = nil;
  _encryptedData = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:outError];
  return YES;
}

- (BOOL)revertToContentsOfURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError {
  self.tree = nil;
  if([self readFromURL:absoluteURL ofType:typeName error:outError]) {
    [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentDidRevertNotifiation object:self];
    return YES;
  }
  return NO;
}

- (BOOL)isEntireFileLoaded {
  return YES;
}

- (void)close {
  [self _cleanupLock];
  /*
   We store the last url. Restored windows are automatically handeld.
   If closeAllDocuments is set, all docs get this messgae
   */
  if([[self fileURL] isFileURL]) {
    [[NSUserDefaults standardUserDefaults] setObject:[self.fileURL absoluteString] forKey:kMPSettingsKeyLastDatabasePath];
  }
  [super close];
}

- (BOOL)shouldRunSavePanelWithAccessoryView {
  return NO;
}

- (BOOL)prepareSavePanel:(NSSavePanel *)savePanel {
  if(!self.savePanelViewController) {
    self.savePanelViewController = [[MPSavePanelAccessoryViewController alloc] init];
  }
  self.savePanelViewController.savePanel = savePanel;
  self.savePanelViewController.document = self;
  
  [savePanel setAccessoryView:[self.savePanelViewController view]];
  [self.savePanelViewController updateView];
  
  return YES;
}

- (NSString *)fileTypeFromLastRunSavePanel {
  if(self.savePanelViewController) {
    return [[self class] fileTypeForVersion:self.savePanelViewController.selectedVersion];
  }
  return [self fileType];
}

- (void)writeXMLToURL:(NSURL *)url {
  NSData *xmlData = [self.tree xmlData];
  [xmlData writeToURL:url atomically:YES];
}

- (void)readXMLfromURL:(NSURL *)url {
  NSError *error;
  self.tree = [[KPKTree alloc] initWithXmlContentsOfURL:url error:&error];
  self.compositeKey = nil;
  _encryptedData = Nil;
}

#pragma mark Lock/Unlock/Decrypt

- (void)lockDatabase:(id)sender {
  [self exitSearch:self];
  NSError *error;
  /* Locking needs to be lossless hence just use the XML format */
  _encryptedData = [self.tree encryptWithPassword:self.compositeKey forVersion:KPKXmlVersion error:&error];
  self.tree = nil;
}

- (BOOL)unlockWithPassword:(NSString *)password keyFileURL:(NSURL *)keyFileURL error:(NSError *__autoreleasing*)error{
  self.compositeKey = [[KPKCompositeKey alloc] initWithPassword:password key:keyFileURL];
  self.tree = [[KPKTree alloc] initWithData:_encryptedData password:self.compositeKey error:error];
  
  BOOL isUnlocked = (nil != self.tree);
  if(isUnlocked) {
    [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentDidUnlockDatabaseNotification object:self];
    /* Make sure to only store */
    MPAppDelegate *delegate = [NSApp delegate];
    if(self.compositeKey.hasKeyFile && self.compositeKey.hasPassword && delegate.isAllowedToStoreKeyFile) {
      [self _storeKeyURL:keyFileURL];
    }
  }
  else {
    self.compositeKey = nil; // clear the key?
  }
  return isUnlocked;
}

- (BOOL)changePassword:(NSString *)password keyFileURL:(NSURL *)keyFileURL {
  /* sanity check? */
  if([password length] == 0 && keyFileURL == nil) {
    return NO;
  }
  if(!self.compositeKey) {
    self.compositeKey = [[KPKCompositeKey alloc] initWithPassword:password key:keyFileURL];
  }
  else {
    [self.compositeKey setPassword:password andKeyfile:keyFileURL];
  }
  self.tree.metaData.masterKeyChanged = [NSDate date];
  /* We need to store the key file once the user actually writes the database */
  return YES;
}

- (NSURL *)suggestedKeyURL {
  MPAppDelegate *delegate = [NSApp delegate];
  if(!delegate.isAllowedToStoreKeyFile) {
    return nil;
  }
  NSDictionary *keysForFiles = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kMPSettingsKeyRememeberdKeysForDatabases];
  NSString *keyPath = keysForFiles[[[self fileURL] path]];
  if(!keyPath) {
    return nil;
  }
  return [NSURL fileURLWithPath:keyPath];
}

#pragma mark Properties
- (KPKVersion)versionForFileType {
  return [[self class] versionForFileType:[self fileType]];
}

- (BOOL)encrypted {
  return (self.tree == nil);
}

- (KPKGroup *)root {
  return self.tree.root;
}

- (KPKGroup *)trash {
  /* Caching is dangerous, as we might have deleted the trashcan */
  if(self.useTrash) {
    return [self findGroup:self.tree.metaData.recycleBinUuid];
  }
  return nil;
}

- (BOOL)useTrash {
  return self.tree.metaData.recycleBinEnabled;
}

- (KPKGroup *)templates {
  /* Caching is dangerous as we might have deleted the group */
  return [self findGroup:self.tree.metaData.entryTemplatesGroup];
}

- (void)setTrash:(KPKGroup *)trash {
  if(self.useTrash) {
    if(![self.tree.metaData.recycleBinUuid isEqual:trash.uuid]) {
      self.tree.metaData.recycleBinUuid = trash.uuid;
    }
  }
}

- (void)setTemplates:(KPKGroup *)templates {
  if(![self.tree.metaData.entryTemplatesGroup isEqual:templates.uuid]) {
    self.tree.metaData.entryTemplatesGroup = templates.uuid;
  }
}

- (void)setSelectedGroup:(KPKGroup *)selectedGroup {
  if(_selectedGroup != selectedGroup) {
    _selectedGroup = selectedGroup;
  }
  self.selectedItem = _selectedGroup;
}

- (void)setSelectedEntry:(KPKEntry *)selectedEntry {
  if(_selectedEntry != selectedEntry) {
    _selectedEntry = selectedEntry;
  }
  self.selectedItem = selectedEntry;
}

- (void)setSelectedItem:(id)selectedItem {
  if(_selectedItem != selectedItem) {
    _selectedItem = selectedItem;
    [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentCurrentItemChangedNotification object:self];
  }
}
- (void)setTree:(KPKTree *)tree {
  if(_tree != tree) {
    _tree = tree;
    _tree.undoManager = [self undoManager];
  }
}

#pragma mark Data Accesors

- (KPKEntry *)findEntry:(NSUUID *)uuid {
  return [self.root entryForUUID:uuid];
}

- (KPKGroup *)findGroup:(NSUUID *)uuid {
  return [self.root groupForUUID:uuid];
}

- (NSArray *)allEntries {
  return self.tree.allEntries;
}

- (NSArray *)allGroups {
  return self.tree.allGroups;
}

- (BOOL)isItemTrashed:(id)item {
  BOOL validItem = [item isKindOfClass:[KPKEntry class]] || [item isKindOfClass:[KPKGroup class]];
  if(!item) {
    return NO;
  }
  if(item == self.trash) {
    return NO; // No need to look further as this is the trashcan
  }
  if(validItem) {
    BOOL isTrashed = NO;
    id parent = [item parent];
    while( parent && !isTrashed ) {
      isTrashed = (parent == self.trash);
      parent = [parent parent];
    }
    return isTrashed;
  }
  return NO;
}

#pragma mark Data manipulation
- (KPKEntry *)createEntry:(KPKGroup *)parent {
  if(!parent) {
    return nil; // No parent
  }
  if(parent == self.trash) {
    return nil; // no new Groups in trash
  }
  if([self isItemTrashed:parent]) {
    return nil;
  }
  KPKEntry *newEntry = [self.tree createEntry:parent];
  newEntry.title = NSLocalizedString(@"DEFAULT_ENTRY_TITLE", @"Title for a newly created entry");
  if([self.tree.metaData.defaultUserName length] > 0) {
    newEntry.title = self.tree.metaData.defaultUserName;
  }
  [parent addEntry:newEntry];
  [parent.undoManager setActionName:NSLocalizedString(@"ADD_ENTRY", "")];
  return newEntry;
}

- (KPKGroup *)createGroup:(KPKGroup *)parent {
  if(!parent) {
    return nil; // no parent!
  }
  if(parent == self.trash) {
    return nil; // no new Groups in trash
  }
  if([self isItemTrashed:parent]) {
    return nil;
  }
  KPKGroup *newGroup = [self.tree createGroup:parent];
  newGroup.name = NSLocalizedString(@"DEFAULT_GROUP_NAME", @"Title for a newly created group");
  newGroup.iconId = MPIconFolder;
  [parent addGroup:newGroup];
  NSDictionary *userInfo = @{ MPDocumentGroupKey : newGroup };
  [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentDidAddGroupNotification object:self userInfo:userInfo];
  return newGroup;
}

- (KPKAttribute *)createCustomAttribute:(KPKEntry *)entry {
  NSString *title = NSLocalizedString(@"DEFAULT_CUSTOM_FIELD_TITLE", @"Default Titel for new Custom-Fields");
  NSString *value = NSLocalizedString(@"DEFAULT_CUSTOM_FIELD_VALUE", @"Default Value for new Custom-Fields");
  title = [entry proposedKeyForAttributeKey:title];
  KPKAttribute *newAttribute = [[KPKAttribute alloc] initWithKey:title value:value];
  [entry addCustomAttribute:newAttribute];
  return newAttribute;
}

- (void)deleteEntry:(KPKEntry *)entry {
  if(self.useTrash) {
    if([self isItemTrashed:entry]) {
      return; // Entry is already trashed
    }
    if(!self.trash) {
      [self _createTrashGroup];
    }
    [entry moveToGroup:self.trash atIndex:[self.trash.entries count]];
    [[self undoManager] setActionName:NSLocalizedString(@"TRASH_ENTRY", "Move Entry to Trash")];
  }
  else {
    [entry remove];
    [[self undoManager] setActionName:NSLocalizedString(@"DELETE_ENTRY", "")];
  }
  if(self.selectedEntry == entry) {
    self.selectedEntry = nil;
  }
}

- (void)deleteGroup:(KPKGroup *)group {
  if(self.useTrash) {
    if(!self.trash) {
      [self _createTrashGroup];
    }
    if( (group == self.trash) || [self isItemTrashed:group] ) {
      return; //Groups already trashed cannot be deleted
    }
    [group moveToGroup:self.trash atIndex:[self.trash.groups count]];
    [[self undoManager] setActionName:NSLocalizedString(@"TRASH_GROUP", "Move Group to Trash")];
  }
  else {
    [group remove];
    [[self undoManager] setActionName:NSLocalizedString(@"DELETE_GROUP", "Delete Group")];
  }
}

#pragma mark Actions


- (void)emptyTrash:(id)sender {
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setAlertStyle:NSWarningAlertStyle];
  [alert setMessageText:NSLocalizedString(@"WARNING_ON_EMPTY_TRASH_TITLE", "")];
  [alert setInformativeText:NSLocalizedString(@"WARNING_ON_EMPTY_TRASH_DESCRIPTION", "Informative Text displayed when clearing the Trash")];
  [alert addButtonWithTitle:NSLocalizedString(@"EMPTY_TRASH", "Empty Trash")];
  [alert addButtonWithTitle:NSLocalizedString(@"CANCEL", "Cancel")];
  
  [[alert buttons][1] setKeyEquivalent:[NSString stringWithFormat:@"%c", 0x1b]];
  
  NSWindow *window = [[self windowControllers][0] window];
  [alert beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(_emptyTrashAlertDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (void)_emptyTrashAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo {
  if(returnCode == NSAlertFirstButtonReturn) {
    [self _emptyTrash];
  }
}

- (void)createEntryFromTemplate:(id)sender {
  if(![sender respondsToSelector:@selector(representedObject)]) {
    return; // sender cannot provide usefull data
  }
  id obj = [sender representedObject];
  if([obj isKindOfClass:[NSUUID class]]) {
    return; // sender cannot provide NSUUID
  }
  NSUUID *entryUUID = [sender representedObject];
  if(entryUUID) {
    KPKEntry *templateEntry = [self findEntry:entryUUID];
    if(templateEntry && self.selectedGroup) {
      KPKEntry *copy = [templateEntry copyWithTitle:templateEntry.title];
      [self.selectedGroup addEntry:copy];
      [self.selectedGroup.undoManager setActionName:NSLocalizedString(@"ADD_TREMPLATE_ENTRY", "")];
    }
  }
}

- (void)cloneEntry:(id)sender {
  KPKEntry *clone = [self.selectedEntry copyWithTitle:nil];
  NSInteger index = [self.selectedEntry.parent.entries indexOfObject:self.selectedEntry];
  [self.selectedEntry.parent addEntry:clone atIndex:index+1];
  [self.undoManager setActionName:NSLocalizedString(@"CLONE_ENTRY", "")];
}

- (void)cloneEntryWithOptions:(id)sender {
}


#pragma mark Validation
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
  return [self validateUserInterfaceItem:menuItem];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)theItem {
  return [self validateUserInterfaceItem:theItem];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)anItem {
  if(self.encrypted || self.isReadOnly) { return NO; }
  
  BOOL valid = YES;
  switch([MPActionHelper typeForAction:[anItem action]]) {
    case MPActionAddGroup:
      valid &= (nil != self.selectedGroup);
      // fall-through
    case MPActionAddEntry:
      // fall-through
    case MPActionDelete:
      valid &= (nil != self.selectedItem);
      valid &= (self.trash != self.selectedItem);
      valid &= ![self isItemTrashed:self.selectedItem];
      break;
    case MPActionCloneEntry:
      //case MPActionCloneEntryWithOptions:
      valid &= (nil != self.selectedItem);
      valid &= self.selectedEntry == self.selectedItem;
      break;
    case MPActionEmptyTrash:
      valid &= [self.trash.groups count] > 0;
      valid &= [self.trash.entries count] > 0;
      break;
    case MPActionDatabaseSettings:
    case MPActionEditPassword:
      valid &= !self.encrypted;
      break;
    case MPActionLock:
      valid &= self.compositeKey.hasPasswordOrKeyFile;
      break;
    default:
      valid = YES;
  }
  return (valid && [super validateUserInterfaceItem:anItem]);
}

- (void)_storeKeyURL:(NSURL *)keyURL {
  if(nil == keyURL) {
    return; // no URL to store in the first place
  }
  MPAppDelegate *delegate = [NSApp delegate];
  NSAssert(delegate.isAllowedToStoreKeyFile, @"We can only store if we are allowed to do so!");
  NSMutableDictionary *keysForFiles = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kMPSettingsKeyRememeberdKeysForDatabases] mutableCopy];
  if(nil == keysForFiles) {
    keysForFiles = [[NSMutableDictionary alloc] initWithCapacity:1];
  }
  keysForFiles[[[self fileURL] path]] = [keyURL path];
  [[NSUserDefaults standardUserDefaults] setObject:keysForFiles forKey:kMPSettingsKeyRememeberdKeysForDatabases];
}

- (void)_cleanupLock {
  if(_didLockFile) {
    [[NSFileManager defaultManager] removeItemAtURL:_lockFileURL error:nil];
    _didLockFile = NO;
  }
}

- (KPKGroup *)_createTrashGroup {
  /* Maybe push the stuff to the Tree? */
  KPKGroup *trash = [self.tree createGroup:self.tree.root];
  BOOL wasEnabled = [self.undoManager isUndoRegistrationEnabled];
  [self.undoManager disableUndoRegistration];
  trash.name = NSLocalizedString(@"TRASH", @"Name for the trash group");
  trash.iconId = MPIconTrash;
  [self.tree.root addGroup:trash];
  if(wasEnabled) {
    [self.undoManager enableUndoRegistration];
  }
  self.tree.metaData.recycleBinUuid = trash.uuid;
  return trash;
}

- (void)_emptyTrash {
  for(KPKEntry *entry in [self.trash childEntries]) {
    [[self undoManager] removeAllActionsWithTarget:entry];
  }
  for(KPKGroup *group in [self.trash childGroups]) {
    [[self undoManager] removeAllActionsWithTarget:group];
  }
  [self.trash clear];
}

@end
