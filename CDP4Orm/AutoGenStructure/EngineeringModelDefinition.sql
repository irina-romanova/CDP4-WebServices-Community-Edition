﻿CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE SCHEMA "EngineeringModel_REPLACE";

CREATE SEQUENCE "EngineeringModel_REPLACE"."Revision" MINVALUE 1 START 1;

CREATE TABLE "EngineeringModel_REPLACE"."RevisionRegistry"
(
  "Revision" integer NOT NULL,
  "Instant" timestamp NOT NULL,
  "Actor" uuid
);

CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE".get_current_revision() RETURNS INTEGER 
  LANGUAGE plpgsql
  AS $$
DECLARE
  transaction_time timestamp without time zone;
  revision integer;
  audit_enabled boolean;
  actor_id uuid;
BEGIN
  -- get the current transaction time
  transaction_time := "SiteDirectory".get_transaction_time();
  actor_id := "SiteDirectory".get_session_user();
  
  -- try and get the current revision
  SELECT "Revision" INTO revision FROM "EngineeringModel_REPLACE"."RevisionRegistry" WHERE "Instant" = transaction_time;
  
  IF(revision IS NULL) THEN
  
    -- no revision registry entry for this transaction; increase revision number
    SELECT nextval('"EngineeringModel_REPLACE"."Revision"') INTO revision;
    EXECUTE 'INSERT INTO "EngineeringModel_REPLACE"."RevisionRegistry" ("Revision", "Instant", "Actor") VALUES($1, $2, $3);' USING revision, transaction_time, actor_id;
  
    -- make sure to log the updated state of top container updates (even if audit logging is temporarily turned off)
    audit_enabled := "SiteDirectory".get_audit_enabled();
    IF (NOT audit_enabled) THEN
      -- enabled audit logging
      EXECUTE 'UPDATE transaction_info SET audit_enabled = true;';
    END IF;

    -- update the revision number and last modified on properties of the top container
    EXECUTE 'UPDATE "EngineeringModel_REPLACE"."TopContainer" SET "ValueTypeDictionary" = "ValueTypeDictionary" || ''"LastModifiedOn" => "' || transaction_time || '"'';';
    EXECUTE 'UPDATE "EngineeringModel_REPLACE"."Thing" SET "ValueTypeDictionary" = "ValueTypeDictionary" || ''"RevisionNumber" => "' || revision || '"'' WHERE "Iid" = ANY(SELECT "Iid" FROM "EngineeringModel_REPLACE"."TopContainer");';
  
    IF (NOT audit_enabled) THEN
      -- turn off auditing again for remainder of transaction
      EXECUTE 'UPDATE transaction_info SET audit_enabled = false;';
    END IF;

  END IF;
  
  -- return the current revision number
  RETURN revision;
END;
$$;

CREATE TABLE "EngineeringModel_REPLACE"."IterationRevisionLog"
(
  "IterationIid" uuid NOT NULL,
  "FromRevision" integer NOT NULL DEFAULT "EngineeringModel_REPLACE".get_current_revision(),
  "ToRevision" integer
);

CREATE VIEW "EngineeringModel_REPLACE"."IterationRevisionLog_View" AS
SELECT 
  iteration_log."IterationIid", 
  revision_from."Revision" AS "FromRevision", 
  revision_from."Instant" AS "ValidFrom", 
  revision_to."Revision" AS "ToRevision", 
  CASE
    WHEN iteration_log."ToRevision" IS NULL THEN 'infinity'
    ELSE revision_to."Instant"
  END AS "ValidTo"
FROM "EngineeringModel_REPLACE"."IterationRevisionLog" iteration_log
LEFT JOIN "EngineeringModel_REPLACE"."RevisionRegistry" revision_from ON iteration_log."FromRevision" = revision_from."Revision" 
LEFT JOIN "EngineeringModel_REPLACE"."RevisionRegistry" revision_to ON iteration_log."ToRevision" = revision_to."Revision";

CREATE SCHEMA "Iteration_REPLACE";

-- Create table for class Thing
CREATE TABLE "EngineeringModel_REPLACE"."Thing" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Thing_PK" PRIMARY KEY ("Iid")
);
CREATE TRIGGER thing_apply_revision
  BEFORE INSERT 
  ON "EngineeringModel_REPLACE"."Thing"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Iid', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Create table for class TopContainer (which derives from: Thing)
CREATE TABLE "EngineeringModel_REPLACE"."TopContainer" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "TopContainer_PK" PRIMARY KEY ("Iid")
);
-- Create table for class EngineeringModel (which derives from: TopContainer)
CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModel" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "EngineeringModel_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for EngineeringModel
CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModel_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "EngineeringModel_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for EngineeringModel
CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModel_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "EngineeringModel_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "EngineeringModelCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class FileStore (which derives from: Thing and implements: NamedThing, TimeStampedThing, OwnedThing)
CREATE TABLE "EngineeringModel_REPLACE"."FileStore" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "FileStore_PK" PRIMARY KEY ("Iid")
);
-- Create table for class CommonFileStore (which derives from: FileStore)
CREATE TABLE "EngineeringModel_REPLACE"."CommonFileStore" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "CommonFileStore_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for CommonFileStore
CREATE TABLE "EngineeringModel_REPLACE"."CommonFileStore_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "CommonFileStore_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for CommonFileStore
CREATE TABLE "EngineeringModel_REPLACE"."CommonFileStore_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "CommonFileStore_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "CommonFileStoreCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Folder (which derives from: Thing and implements: OwnedThing, NamedThing, TimeStampedThing)
CREATE TABLE "EngineeringModel_REPLACE"."Folder" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Folder_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Folder
CREATE TABLE "EngineeringModel_REPLACE"."Folder_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Folder_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Folder
CREATE TABLE "EngineeringModel_REPLACE"."Folder_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Folder_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "FolderCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class File (which derives from: Thing and implements: OwnedThing, CategorizableThing)
CREATE TABLE "EngineeringModel_REPLACE"."File" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "File_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for File
CREATE TABLE "EngineeringModel_REPLACE"."File_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "File_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for File
CREATE TABLE "EngineeringModel_REPLACE"."File_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "File_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "FileCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class FileRevision (which derives from: Thing and implements: TimeStampedThing, NamedThing)
CREATE TABLE "EngineeringModel_REPLACE"."FileRevision" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "FileRevision_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for FileRevision
CREATE TABLE "EngineeringModel_REPLACE"."FileRevision_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "FileRevision_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for FileRevision
CREATE TABLE "EngineeringModel_REPLACE"."FileRevision_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "FileRevision_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "FileRevisionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ModelLogEntry (which derives from: Thing and implements: Annotation, TimeStampedThing, CategorizableThing, LogEntry)
CREATE TABLE "EngineeringModel_REPLACE"."ModelLogEntry" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ModelLogEntry_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ModelLogEntry
CREATE TABLE "EngineeringModel_REPLACE"."ModelLogEntry_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ModelLogEntry_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ModelLogEntry
CREATE TABLE "EngineeringModel_REPLACE"."ModelLogEntry_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ModelLogEntry_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ModelLogEntryCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Iteration (which derives from: Thing)
CREATE TABLE "EngineeringModel_REPLACE"."Iteration" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Iteration_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Iteration
CREATE TABLE "EngineeringModel_REPLACE"."Iteration_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Iteration_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Iteration
CREATE TABLE "EngineeringModel_REPLACE"."Iteration_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Iteration_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "IterationCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Book (which derives from: Thing and implements: ShortNamedThing, NamedThing, CategorizableThing, TimeStampedThing, OwnedThing)
CREATE TABLE "EngineeringModel_REPLACE"."Book" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Book_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Book
CREATE TABLE "EngineeringModel_REPLACE"."Book_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Book_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Book
CREATE TABLE "EngineeringModel_REPLACE"."Book_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Book_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "BookCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Section (which derives from: Thing and implements: ShortNamedThing, NamedThing, CategorizableThing, TimeStampedThing, OwnedThing)
CREATE TABLE "EngineeringModel_REPLACE"."Section" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Section_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Section
CREATE TABLE "EngineeringModel_REPLACE"."Section_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Section_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Section
CREATE TABLE "EngineeringModel_REPLACE"."Section_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Section_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "SectionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Page (which derives from: Thing and implements: ShortNamedThing, NamedThing, CategorizableThing, TimeStampedThing, OwnedThing)
CREATE TABLE "EngineeringModel_REPLACE"."Page" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Page_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Page
CREATE TABLE "EngineeringModel_REPLACE"."Page_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Page_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Page
CREATE TABLE "EngineeringModel_REPLACE"."Page_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Page_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "PageCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Note (which derives from: Thing and implements: ShortNamedThing, NamedThing, CategorizableThing, TimeStampedThing, OwnedThing)
CREATE TABLE "EngineeringModel_REPLACE"."Note" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Note_PK" PRIMARY KEY ("Iid")
);
-- Create table for class BinaryNote (which derives from: Note)
CREATE TABLE "EngineeringModel_REPLACE"."BinaryNote" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "BinaryNote_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for BinaryNote
CREATE TABLE "EngineeringModel_REPLACE"."BinaryNote_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "BinaryNote_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for BinaryNote
CREATE TABLE "EngineeringModel_REPLACE"."BinaryNote_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "BinaryNote_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "BinaryNoteCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class TextualNote (which derives from: Note)
CREATE TABLE "EngineeringModel_REPLACE"."TextualNote" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "TextualNote_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for TextualNote
CREATE TABLE "EngineeringModel_REPLACE"."TextualNote_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "TextualNote_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for TextualNote
CREATE TABLE "EngineeringModel_REPLACE"."TextualNote_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "TextualNote_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "TextualNoteCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class GenericAnnotation (which derives from: Thing and implements: Annotation, TimeStampedThing)
CREATE TABLE "EngineeringModel_REPLACE"."GenericAnnotation" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "GenericAnnotation_PK" PRIMARY KEY ("Iid")
);
-- Create table for class EngineeringModelDataAnnotation (which derives from: GenericAnnotation)
CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "EngineeringModelDataAnnotation_PK" PRIMARY KEY ("Iid")
);
-- Create table for class EngineeringModelDataNote (which derives from: EngineeringModelDataAnnotation)
CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModelDataNote" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "EngineeringModelDataNote_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for EngineeringModelDataNote
CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModelDataNote_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "EngineeringModelDataNote_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for EngineeringModelDataNote
CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModelDataNote_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "EngineeringModelDataNote_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "EngineeringModelDataNoteCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ThingReference (which derives from: Thing)
CREATE TABLE "EngineeringModel_REPLACE"."ThingReference" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ThingReference_PK" PRIMARY KEY ("Iid")
);
-- Create table for class ModellingThingReference (which derives from: ThingReference)
CREATE TABLE "EngineeringModel_REPLACE"."ModellingThingReference" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ModellingThingReference_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ModellingThingReference
CREATE TABLE "EngineeringModel_REPLACE"."ModellingThingReference_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ModellingThingReference_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ModellingThingReference
CREATE TABLE "EngineeringModel_REPLACE"."ModellingThingReference_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ModellingThingReference_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ModellingThingReferenceCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class DiscussionItem (which derives from: GenericAnnotation)
CREATE TABLE "EngineeringModel_REPLACE"."DiscussionItem" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DiscussionItem_PK" PRIMARY KEY ("Iid")
);
-- Create table for class EngineeringModelDataDiscussionItem (which derives from: DiscussionItem)
CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "EngineeringModelDataDiscussionItem_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for EngineeringModelDataDiscussionItem
CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "EngineeringModelDataDiscussionItem_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for EngineeringModelDataDiscussionItem
CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "EngineeringModelDataDiscussionItem_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "EngineeringModelDataDiscussionItemCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ModellingAnnotationItem (which derives from: EngineeringModelDataAnnotation and implements: OwnedThing, ShortNamedThing, CategorizableThing)
CREATE TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ModellingAnnotationItem_PK" PRIMARY KEY ("Iid")
);
-- Create table for class ContractDeviation (which derives from: ModellingAnnotationItem)
CREATE TABLE "EngineeringModel_REPLACE"."ContractDeviation" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ContractDeviation_PK" PRIMARY KEY ("Iid")
);
-- Create table for class RequestForWaiver (which derives from: ContractDeviation)
CREATE TABLE "EngineeringModel_REPLACE"."RequestForWaiver" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RequestForWaiver_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for RequestForWaiver
CREATE TABLE "EngineeringModel_REPLACE"."RequestForWaiver_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RequestForWaiver_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for RequestForWaiver
CREATE TABLE "EngineeringModel_REPLACE"."RequestForWaiver_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RequestForWaiver_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "RequestForWaiverCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Approval (which derives from: GenericAnnotation and implements: OwnedThing)
CREATE TABLE "EngineeringModel_REPLACE"."Approval" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Approval_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Approval
CREATE TABLE "EngineeringModel_REPLACE"."Approval_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Approval_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Approval
CREATE TABLE "EngineeringModel_REPLACE"."Approval_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Approval_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ApprovalCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class RequestForDeviation (which derives from: ContractDeviation)
CREATE TABLE "EngineeringModel_REPLACE"."RequestForDeviation" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RequestForDeviation_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for RequestForDeviation
CREATE TABLE "EngineeringModel_REPLACE"."RequestForDeviation_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RequestForDeviation_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for RequestForDeviation
CREATE TABLE "EngineeringModel_REPLACE"."RequestForDeviation_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RequestForDeviation_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "RequestForDeviationCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ChangeRequest (which derives from: ContractDeviation)
CREATE TABLE "EngineeringModel_REPLACE"."ChangeRequest" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ChangeRequest_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ChangeRequest
CREATE TABLE "EngineeringModel_REPLACE"."ChangeRequest_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ChangeRequest_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ChangeRequest
CREATE TABLE "EngineeringModel_REPLACE"."ChangeRequest_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ChangeRequest_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ChangeRequestCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ReviewItemDiscrepancy (which derives from: ModellingAnnotationItem)
CREATE TABLE "EngineeringModel_REPLACE"."ReviewItemDiscrepancy" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ReviewItemDiscrepancy_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ReviewItemDiscrepancy
CREATE TABLE "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ReviewItemDiscrepancy_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ReviewItemDiscrepancy
CREATE TABLE "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ReviewItemDiscrepancy_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ReviewItemDiscrepancyCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Solution (which derives from: GenericAnnotation and implements: OwnedThing)
CREATE TABLE "EngineeringModel_REPLACE"."Solution" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Solution_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Solution
CREATE TABLE "EngineeringModel_REPLACE"."Solution_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Solution_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Solution
CREATE TABLE "EngineeringModel_REPLACE"."Solution_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Solution_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "SolutionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ActionItem (which derives from: ModellingAnnotationItem)
CREATE TABLE "EngineeringModel_REPLACE"."ActionItem" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ActionItem_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ActionItem
CREATE TABLE "EngineeringModel_REPLACE"."ActionItem_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ActionItem_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ActionItem
CREATE TABLE "EngineeringModel_REPLACE"."ActionItem_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ActionItem_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ActionItemCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ChangeProposal (which derives from: ModellingAnnotationItem)
CREATE TABLE "EngineeringModel_REPLACE"."ChangeProposal" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ChangeProposal_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ChangeProposal
CREATE TABLE "EngineeringModel_REPLACE"."ChangeProposal_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ChangeProposal_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ChangeProposal
CREATE TABLE "EngineeringModel_REPLACE"."ChangeProposal_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ChangeProposal_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ChangeProposalCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ContractChangeNotice (which derives from: ModellingAnnotationItem)
CREATE TABLE "EngineeringModel_REPLACE"."ContractChangeNotice" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ContractChangeNotice_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ContractChangeNotice
CREATE TABLE "EngineeringModel_REPLACE"."ContractChangeNotice_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ContractChangeNotice_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ContractChangeNotice
CREATE TABLE "EngineeringModel_REPLACE"."ContractChangeNotice_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ContractChangeNotice_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ContractChangeNoticeCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Thing
CREATE TABLE "Iteration_REPLACE"."Thing" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Thing_PK" PRIMARY KEY ("Iid")
);
CREATE TRIGGER thing_apply_revision
  BEFORE INSERT 
  ON "Iteration_REPLACE"."Thing"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Iid', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Create table for class DefinedThing (which derives from: Thing and implements: NamedThing, ShortNamedThing)
CREATE TABLE "Iteration_REPLACE"."DefinedThing" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DefinedThing_PK" PRIMARY KEY ("Iid")
);
-- Create table for class Option (which derives from: DefinedThing and implements: CategorizableThing)
CREATE TABLE "Iteration_REPLACE"."Option" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Option_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Option
CREATE TABLE "Iteration_REPLACE"."Option_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Option_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Option
CREATE TABLE "Iteration_REPLACE"."Option_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Option_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "OptionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Alias (which derives from: Thing and implements: Annotation)
CREATE TABLE "Iteration_REPLACE"."Alias" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Alias_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Alias
CREATE TABLE "Iteration_REPLACE"."Alias_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Alias_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Alias
CREATE TABLE "Iteration_REPLACE"."Alias_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Alias_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "AliasCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Definition (which derives from: Thing and implements: Annotation)
CREATE TABLE "Iteration_REPLACE"."Definition" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Definition_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Definition
CREATE TABLE "Iteration_REPLACE"."Definition_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Definition_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Definition
CREATE TABLE "Iteration_REPLACE"."Definition_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Definition_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "DefinitionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Citation (which derives from: Thing and implements: ShortNamedThing)
CREATE TABLE "Iteration_REPLACE"."Citation" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Citation_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Citation
CREATE TABLE "Iteration_REPLACE"."Citation_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Citation_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Citation
CREATE TABLE "Iteration_REPLACE"."Citation_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Citation_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "CitationCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class HyperLink (which derives from: Thing and implements: Annotation)
CREATE TABLE "Iteration_REPLACE"."HyperLink" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "HyperLink_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for HyperLink
CREATE TABLE "Iteration_REPLACE"."HyperLink_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "HyperLink_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for HyperLink
CREATE TABLE "Iteration_REPLACE"."HyperLink_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "HyperLink_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "HyperLinkCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class NestedElement (which derives from: Thing and implements: NamedThing, ShortNamedThing, OwnedThing, VolatileThing)
CREATE TABLE "Iteration_REPLACE"."NestedElement" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "NestedElement_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for NestedElement
CREATE TABLE "Iteration_REPLACE"."NestedElement_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "NestedElement_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for NestedElement
CREATE TABLE "Iteration_REPLACE"."NestedElement_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "NestedElement_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "NestedElementCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class NestedParameter (which derives from: Thing and implements: OwnedThing, VolatileThing)
CREATE TABLE "Iteration_REPLACE"."NestedParameter" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "NestedParameter_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for NestedParameter
CREATE TABLE "Iteration_REPLACE"."NestedParameter_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "NestedParameter_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for NestedParameter
CREATE TABLE "Iteration_REPLACE"."NestedParameter_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "NestedParameter_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "NestedParameterCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Publication (which derives from: Thing and implements: TimeStampedThing)
CREATE TABLE "Iteration_REPLACE"."Publication" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Publication_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Publication
CREATE TABLE "Iteration_REPLACE"."Publication_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Publication_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Publication
CREATE TABLE "Iteration_REPLACE"."Publication_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Publication_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "PublicationCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class PossibleFiniteStateList (which derives from: DefinedThing and implements: CategorizableThing, OwnedThing)
CREATE TABLE "Iteration_REPLACE"."PossibleFiniteStateList" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "PossibleFiniteStateList_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for PossibleFiniteStateList
CREATE TABLE "Iteration_REPLACE"."PossibleFiniteStateList_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "PossibleFiniteStateList_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for PossibleFiniteStateList
CREATE TABLE "Iteration_REPLACE"."PossibleFiniteStateList_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "PossibleFiniteStateList_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "PossibleFiniteStateListCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class PossibleFiniteState (which derives from: DefinedThing and implements: OwnedThing)
CREATE TABLE "Iteration_REPLACE"."PossibleFiniteState" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "PossibleFiniteState_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for PossibleFiniteState
CREATE TABLE "Iteration_REPLACE"."PossibleFiniteState_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "PossibleFiniteState_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for PossibleFiniteState
CREATE TABLE "Iteration_REPLACE"."PossibleFiniteState_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "PossibleFiniteState_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "PossibleFiniteStateCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ElementBase (which derives from: DefinedThing and implements: CategorizableThing, OwnedThing)
CREATE TABLE "Iteration_REPLACE"."ElementBase" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ElementBase_PK" PRIMARY KEY ("Iid")
);
-- Create table for class ElementDefinition (which derives from: ElementBase)
CREATE TABLE "Iteration_REPLACE"."ElementDefinition" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ElementDefinition_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ElementDefinition
CREATE TABLE "Iteration_REPLACE"."ElementDefinition_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ElementDefinition_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ElementDefinition
CREATE TABLE "Iteration_REPLACE"."ElementDefinition_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ElementDefinition_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ElementDefinitionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ElementUsage (which derives from: ElementBase and implements: OptionDependentThing)
CREATE TABLE "Iteration_REPLACE"."ElementUsage" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ElementUsage_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ElementUsage
CREATE TABLE "Iteration_REPLACE"."ElementUsage_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ElementUsage_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ElementUsage
CREATE TABLE "Iteration_REPLACE"."ElementUsage_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ElementUsage_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ElementUsageCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ParameterBase (which derives from: Thing and implements: OwnedThing)
CREATE TABLE "Iteration_REPLACE"."ParameterBase" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParameterBase_PK" PRIMARY KEY ("Iid")
);
-- Create table for class ParameterOrOverrideBase (which derives from: ParameterBase)
CREATE TABLE "Iteration_REPLACE"."ParameterOrOverrideBase" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParameterOrOverrideBase_PK" PRIMARY KEY ("Iid")
);
-- Create table for class ParameterOverride (which derives from: ParameterOrOverrideBase)
CREATE TABLE "Iteration_REPLACE"."ParameterOverride" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParameterOverride_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ParameterOverride
CREATE TABLE "Iteration_REPLACE"."ParameterOverride_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterOverride_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ParameterOverride
CREATE TABLE "Iteration_REPLACE"."ParameterOverride_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterOverride_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ParameterOverrideCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ParameterSubscription (which derives from: ParameterBase)
CREATE TABLE "Iteration_REPLACE"."ParameterSubscription" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParameterSubscription_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ParameterSubscription
CREATE TABLE "Iteration_REPLACE"."ParameterSubscription_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterSubscription_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ParameterSubscription
CREATE TABLE "Iteration_REPLACE"."ParameterSubscription_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterSubscription_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ParameterSubscriptionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ParameterSubscriptionValueSet (which derives from: Thing and implements: OwnedThing)
CREATE TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParameterSubscriptionValueSet_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ParameterSubscriptionValueSet
CREATE TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterSubscriptionValueSet_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ParameterSubscriptionValueSet
CREATE TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterSubscriptionValueSet_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ParameterSubscriptionValueSetCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ParameterValueSetBase (which derives from: Thing and implements: OwnedThing)
CREATE TABLE "Iteration_REPLACE"."ParameterValueSetBase" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParameterValueSetBase_PK" PRIMARY KEY ("Iid")
);
-- Create table for class ParameterOverrideValueSet (which derives from: ParameterValueSetBase)
CREATE TABLE "Iteration_REPLACE"."ParameterOverrideValueSet" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParameterOverrideValueSet_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ParameterOverrideValueSet
CREATE TABLE "Iteration_REPLACE"."ParameterOverrideValueSet_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterOverrideValueSet_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ParameterOverrideValueSet
CREATE TABLE "Iteration_REPLACE"."ParameterOverrideValueSet_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterOverrideValueSet_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ParameterOverrideValueSetCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Parameter (which derives from: ParameterOrOverrideBase)
CREATE TABLE "Iteration_REPLACE"."Parameter" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Parameter_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Parameter
CREATE TABLE "Iteration_REPLACE"."Parameter_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Parameter_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Parameter
CREATE TABLE "Iteration_REPLACE"."Parameter_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Parameter_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ParameterCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ParameterValueSet (which derives from: ParameterValueSetBase)
CREATE TABLE "Iteration_REPLACE"."ParameterValueSet" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParameterValueSet_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ParameterValueSet
CREATE TABLE "Iteration_REPLACE"."ParameterValueSet_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterValueSet_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ParameterValueSet
CREATE TABLE "Iteration_REPLACE"."ParameterValueSet_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterValueSet_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ParameterValueSetCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ParameterGroup (which derives from: Thing and implements: NamedThing)
CREATE TABLE "Iteration_REPLACE"."ParameterGroup" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParameterGroup_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ParameterGroup
CREATE TABLE "Iteration_REPLACE"."ParameterGroup_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterGroup_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ParameterGroup
CREATE TABLE "Iteration_REPLACE"."ParameterGroup_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParameterGroup_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ParameterGroupCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Relationship (which derives from: Thing and implements: CategorizableThing, OwnedThing)
CREATE TABLE "Iteration_REPLACE"."Relationship" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Relationship_PK" PRIMARY KEY ("Iid")
);
-- Create table for class MultiRelationship (which derives from: Relationship)
CREATE TABLE "Iteration_REPLACE"."MultiRelationship" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "MultiRelationship_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for MultiRelationship
CREATE TABLE "Iteration_REPLACE"."MultiRelationship_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "MultiRelationship_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for MultiRelationship
CREATE TABLE "Iteration_REPLACE"."MultiRelationship_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "MultiRelationship_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "MultiRelationshipCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ParameterValue (which derives from: Thing)
CREATE TABLE "Iteration_REPLACE"."ParameterValue" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParameterValue_PK" PRIMARY KEY ("Iid")
);
-- Create table for class RelationshipParameterValue (which derives from: ParameterValue)
CREATE TABLE "Iteration_REPLACE"."RelationshipParameterValue" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RelationshipParameterValue_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for RelationshipParameterValue
CREATE TABLE "Iteration_REPLACE"."RelationshipParameterValue_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RelationshipParameterValue_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for RelationshipParameterValue
CREATE TABLE "Iteration_REPLACE"."RelationshipParameterValue_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RelationshipParameterValue_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "RelationshipParameterValueCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class BinaryRelationship (which derives from: Relationship)
CREATE TABLE "Iteration_REPLACE"."BinaryRelationship" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "BinaryRelationship_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for BinaryRelationship
CREATE TABLE "Iteration_REPLACE"."BinaryRelationship_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "BinaryRelationship_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for BinaryRelationship
CREATE TABLE "Iteration_REPLACE"."BinaryRelationship_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "BinaryRelationship_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "BinaryRelationshipCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ExternalIdentifierMap (which derives from: Thing and implements: NamedThing, OwnedThing)
CREATE TABLE "Iteration_REPLACE"."ExternalIdentifierMap" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ExternalIdentifierMap_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ExternalIdentifierMap
CREATE TABLE "Iteration_REPLACE"."ExternalIdentifierMap_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ExternalIdentifierMap_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ExternalIdentifierMap
CREATE TABLE "Iteration_REPLACE"."ExternalIdentifierMap_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ExternalIdentifierMap_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ExternalIdentifierMapCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class IdCorrespondence (which derives from: Thing and implements: OwnedThing)
CREATE TABLE "Iteration_REPLACE"."IdCorrespondence" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "IdCorrespondence_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for IdCorrespondence
CREATE TABLE "Iteration_REPLACE"."IdCorrespondence_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "IdCorrespondence_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for IdCorrespondence
CREATE TABLE "Iteration_REPLACE"."IdCorrespondence_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "IdCorrespondence_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "IdCorrespondenceCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class RequirementsContainer (which derives from: DefinedThing and implements: OwnedThing, CategorizableThing)
CREATE TABLE "Iteration_REPLACE"."RequirementsContainer" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RequirementsContainer_PK" PRIMARY KEY ("Iid")
);
-- Create table for class RequirementsSpecification (which derives from: RequirementsContainer and implements: DeprecatableThing)
CREATE TABLE "Iteration_REPLACE"."RequirementsSpecification" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RequirementsSpecification_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for RequirementsSpecification
CREATE TABLE "Iteration_REPLACE"."RequirementsSpecification_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RequirementsSpecification_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for RequirementsSpecification
CREATE TABLE "Iteration_REPLACE"."RequirementsSpecification_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RequirementsSpecification_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "RequirementsSpecificationCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class RequirementsGroup (which derives from: RequirementsContainer)
CREATE TABLE "Iteration_REPLACE"."RequirementsGroup" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RequirementsGroup_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for RequirementsGroup
CREATE TABLE "Iteration_REPLACE"."RequirementsGroup_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RequirementsGroup_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for RequirementsGroup
CREATE TABLE "Iteration_REPLACE"."RequirementsGroup_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RequirementsGroup_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "RequirementsGroupCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class RequirementsContainerParameterValue (which derives from: ParameterValue)
CREATE TABLE "Iteration_REPLACE"."RequirementsContainerParameterValue" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RequirementsContainerParameterValue_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for RequirementsContainerParameterValue
CREATE TABLE "Iteration_REPLACE"."RequirementsContainerParameterValue_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RequirementsContainerParameterValue_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for RequirementsContainerParameterValue
CREATE TABLE "Iteration_REPLACE"."RequirementsContainerParameterValue_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RequirementsContainerParameterValue_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "RequirementsContainerParameterValueCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class SimpleParameterizableThing (which derives from: DefinedThing and implements: OwnedThing)
CREATE TABLE "Iteration_REPLACE"."SimpleParameterizableThing" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "SimpleParameterizableThing_PK" PRIMARY KEY ("Iid")
);
-- Create table for class Requirement (which derives from: SimpleParameterizableThing and implements: CategorizableThing, DeprecatableThing)
CREATE TABLE "Iteration_REPLACE"."Requirement" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Requirement_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Requirement
CREATE TABLE "Iteration_REPLACE"."Requirement_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Requirement_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Requirement
CREATE TABLE "Iteration_REPLACE"."Requirement_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Requirement_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "RequirementCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class SimpleParameterValue (which derives from: Thing and implements: OwnedThing)
CREATE TABLE "Iteration_REPLACE"."SimpleParameterValue" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "SimpleParameterValue_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for SimpleParameterValue
CREATE TABLE "Iteration_REPLACE"."SimpleParameterValue_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "SimpleParameterValue_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for SimpleParameterValue
CREATE TABLE "Iteration_REPLACE"."SimpleParameterValue_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "SimpleParameterValue_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "SimpleParameterValueCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ParametricConstraint (which derives from: Thing and implements: OwnedThing)
CREATE TABLE "Iteration_REPLACE"."ParametricConstraint" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ParametricConstraint_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ParametricConstraint
CREATE TABLE "Iteration_REPLACE"."ParametricConstraint_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParametricConstraint_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ParametricConstraint
CREATE TABLE "Iteration_REPLACE"."ParametricConstraint_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ParametricConstraint_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ParametricConstraintCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class BooleanExpression (which derives from: Thing)
CREATE TABLE "Iteration_REPLACE"."BooleanExpression" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "BooleanExpression_PK" PRIMARY KEY ("Iid")
);
-- Create table for class OrExpression (which derives from: BooleanExpression)
CREATE TABLE "Iteration_REPLACE"."OrExpression" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "OrExpression_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for OrExpression
CREATE TABLE "Iteration_REPLACE"."OrExpression_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "OrExpression_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for OrExpression
CREATE TABLE "Iteration_REPLACE"."OrExpression_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "OrExpression_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "OrExpressionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class NotExpression (which derives from: BooleanExpression)
CREATE TABLE "Iteration_REPLACE"."NotExpression" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "NotExpression_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for NotExpression
CREATE TABLE "Iteration_REPLACE"."NotExpression_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "NotExpression_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for NotExpression
CREATE TABLE "Iteration_REPLACE"."NotExpression_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "NotExpression_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "NotExpressionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class AndExpression (which derives from: BooleanExpression)
CREATE TABLE "Iteration_REPLACE"."AndExpression" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "AndExpression_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for AndExpression
CREATE TABLE "Iteration_REPLACE"."AndExpression_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "AndExpression_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for AndExpression
CREATE TABLE "Iteration_REPLACE"."AndExpression_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "AndExpression_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "AndExpressionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ExclusiveOrExpression (which derives from: BooleanExpression)
CREATE TABLE "Iteration_REPLACE"."ExclusiveOrExpression" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ExclusiveOrExpression_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ExclusiveOrExpression
CREATE TABLE "Iteration_REPLACE"."ExclusiveOrExpression_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ExclusiveOrExpression_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ExclusiveOrExpression
CREATE TABLE "Iteration_REPLACE"."ExclusiveOrExpression_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ExclusiveOrExpression_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ExclusiveOrExpressionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class RelationalExpression (which derives from: BooleanExpression)
CREATE TABLE "Iteration_REPLACE"."RelationalExpression" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RelationalExpression_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for RelationalExpression
CREATE TABLE "Iteration_REPLACE"."RelationalExpression_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RelationalExpression_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for RelationalExpression
CREATE TABLE "Iteration_REPLACE"."RelationalExpression_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RelationalExpression_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "RelationalExpressionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class FileStore (which derives from: Thing and implements: NamedThing, TimeStampedThing, OwnedThing)
CREATE TABLE "Iteration_REPLACE"."FileStore" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "FileStore_PK" PRIMARY KEY ("Iid")
);
-- Create table for class DomainFileStore (which derives from: FileStore)
CREATE TABLE "Iteration_REPLACE"."DomainFileStore" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DomainFileStore_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for DomainFileStore
CREATE TABLE "Iteration_REPLACE"."DomainFileStore_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "DomainFileStore_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for DomainFileStore
CREATE TABLE "Iteration_REPLACE"."DomainFileStore_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "DomainFileStore_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "DomainFileStoreCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Folder (which derives from: Thing and implements: OwnedThing, NamedThing, TimeStampedThing)
CREATE TABLE "Iteration_REPLACE"."Folder" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Folder_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Folder
CREATE TABLE "Iteration_REPLACE"."Folder_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Folder_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Folder
CREATE TABLE "Iteration_REPLACE"."Folder_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Folder_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "FolderCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class File (which derives from: Thing and implements: OwnedThing, CategorizableThing)
CREATE TABLE "Iteration_REPLACE"."File" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "File_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for File
CREATE TABLE "Iteration_REPLACE"."File_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "File_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for File
CREATE TABLE "Iteration_REPLACE"."File_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "File_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "FileCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class FileRevision (which derives from: Thing and implements: TimeStampedThing, NamedThing)
CREATE TABLE "Iteration_REPLACE"."FileRevision" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "FileRevision_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for FileRevision
CREATE TABLE "Iteration_REPLACE"."FileRevision_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "FileRevision_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for FileRevision
CREATE TABLE "Iteration_REPLACE"."FileRevision_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "FileRevision_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "FileRevisionCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ActualFiniteStateList (which derives from: Thing and implements: OptionDependentThing, OwnedThing, NamedThing, ShortNamedThing)
CREATE TABLE "Iteration_REPLACE"."ActualFiniteStateList" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ActualFiniteStateList_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ActualFiniteStateList
CREATE TABLE "Iteration_REPLACE"."ActualFiniteStateList_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ActualFiniteStateList_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ActualFiniteStateList
CREATE TABLE "Iteration_REPLACE"."ActualFiniteStateList_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ActualFiniteStateList_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ActualFiniteStateListCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ActualFiniteState (which derives from: Thing and implements: NamedThing, ShortNamedThing, OwnedThing)
CREATE TABLE "Iteration_REPLACE"."ActualFiniteState" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ActualFiniteState_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ActualFiniteState
CREATE TABLE "Iteration_REPLACE"."ActualFiniteState_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ActualFiniteState_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ActualFiniteState
CREATE TABLE "Iteration_REPLACE"."ActualFiniteState_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ActualFiniteState_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ActualFiniteStateCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class RuleVerificationList (which derives from: DefinedThing and implements: OwnedThing)
CREATE TABLE "Iteration_REPLACE"."RuleVerificationList" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RuleVerificationList_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for RuleVerificationList
CREATE TABLE "Iteration_REPLACE"."RuleVerificationList_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RuleVerificationList_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for RuleVerificationList
CREATE TABLE "Iteration_REPLACE"."RuleVerificationList_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RuleVerificationList_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "RuleVerificationListCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class RuleVerification (which derives from: Thing and implements: NamedThing, OwnedThing)
CREATE TABLE "Iteration_REPLACE"."RuleVerification" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RuleVerification_PK" PRIMARY KEY ("Iid")
);
-- Create table for class UserRuleVerification (which derives from: RuleVerification)
CREATE TABLE "Iteration_REPLACE"."UserRuleVerification" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "UserRuleVerification_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for UserRuleVerification
CREATE TABLE "Iteration_REPLACE"."UserRuleVerification_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "UserRuleVerification_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for UserRuleVerification
CREATE TABLE "Iteration_REPLACE"."UserRuleVerification_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "UserRuleVerification_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "UserRuleVerificationCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class RuleViolation (which derives from: Thing)
CREATE TABLE "Iteration_REPLACE"."RuleViolation" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "RuleViolation_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for RuleViolation
CREATE TABLE "Iteration_REPLACE"."RuleViolation_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RuleViolation_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for RuleViolation
CREATE TABLE "Iteration_REPLACE"."RuleViolation_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "RuleViolation_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "RuleViolationCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class BuiltInRuleVerification (which derives from: RuleVerification)
CREATE TABLE "Iteration_REPLACE"."BuiltInRuleVerification" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "BuiltInRuleVerification_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for BuiltInRuleVerification
CREATE TABLE "Iteration_REPLACE"."BuiltInRuleVerification_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "BuiltInRuleVerification_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for BuiltInRuleVerification
CREATE TABLE "Iteration_REPLACE"."BuiltInRuleVerification_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "BuiltInRuleVerification_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "BuiltInRuleVerificationCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Stakeholder (which derives from: DefinedThing and implements: CategorizableThing)
CREATE TABLE "Iteration_REPLACE"."Stakeholder" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Stakeholder_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Stakeholder
CREATE TABLE "Iteration_REPLACE"."Stakeholder_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Stakeholder_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Stakeholder
CREATE TABLE "Iteration_REPLACE"."Stakeholder_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Stakeholder_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "StakeholderCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Goal (which derives from: DefinedThing and implements: CategorizableThing)
CREATE TABLE "Iteration_REPLACE"."Goal" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Goal_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Goal
CREATE TABLE "Iteration_REPLACE"."Goal_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Goal_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Goal
CREATE TABLE "Iteration_REPLACE"."Goal_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Goal_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "GoalCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class ValueGroup (which derives from: DefinedThing and implements: CategorizableThing)
CREATE TABLE "Iteration_REPLACE"."ValueGroup" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "ValueGroup_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for ValueGroup
CREATE TABLE "Iteration_REPLACE"."ValueGroup_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ValueGroup_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for ValueGroup
CREATE TABLE "Iteration_REPLACE"."ValueGroup_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "ValueGroup_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ValueGroupCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class StakeholderValue (which derives from: DefinedThing and implements: CategorizableThing)
CREATE TABLE "Iteration_REPLACE"."StakeholderValue" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "StakeholderValue_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for StakeholderValue
CREATE TABLE "Iteration_REPLACE"."StakeholderValue_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "StakeholderValue_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for StakeholderValue
CREATE TABLE "Iteration_REPLACE"."StakeholderValue_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "StakeholderValue_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "StakeholderValueCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class StakeHolderValueMap (which derives from: DefinedThing and implements: CategorizableThing)
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "StakeHolderValueMap_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for StakeHolderValueMap
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "StakeHolderValueMap_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for StakeHolderValueMap
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "StakeHolderValueMap_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "StakeHolderValueMapCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class StakeHolderValueMapSettings (which derives from: Thing)
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "StakeHolderValueMapSettings_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for StakeHolderValueMapSettings
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "StakeHolderValueMapSettings_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for StakeHolderValueMapSettings
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "StakeHolderValueMapSettings_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "StakeHolderValueMapSettingsCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class DiagramThingBase (which derives from: Thing and implements: NamedThing)
CREATE TABLE "Iteration_REPLACE"."DiagramThingBase" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DiagramThingBase_PK" PRIMARY KEY ("Iid")
);
-- Create table for class DiagrammingStyle (which derives from: DiagramThingBase)
CREATE TABLE "Iteration_REPLACE"."DiagrammingStyle" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DiagrammingStyle_PK" PRIMARY KEY ("Iid")
);
-- Create table for class SharedStyle (which derives from: DiagrammingStyle)
CREATE TABLE "Iteration_REPLACE"."SharedStyle" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "SharedStyle_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for SharedStyle
CREATE TABLE "Iteration_REPLACE"."SharedStyle_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "SharedStyle_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for SharedStyle
CREATE TABLE "Iteration_REPLACE"."SharedStyle_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "SharedStyle_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "SharedStyleCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Color (which derives from: DiagramThingBase)
CREATE TABLE "Iteration_REPLACE"."Color" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Color_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Color
CREATE TABLE "Iteration_REPLACE"."Color_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Color_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Color
CREATE TABLE "Iteration_REPLACE"."Color_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Color_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "ColorCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class DiagramElementContainer (which derives from: DiagramThingBase)
CREATE TABLE "Iteration_REPLACE"."DiagramElementContainer" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DiagramElementContainer_PK" PRIMARY KEY ("Iid")
);
-- Create table for class DiagramCanvas (which derives from: DiagramElementContainer and implements: TimeStampedThing)
CREATE TABLE "Iteration_REPLACE"."DiagramCanvas" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DiagramCanvas_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for DiagramCanvas
CREATE TABLE "Iteration_REPLACE"."DiagramCanvas_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "DiagramCanvas_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for DiagramCanvas
CREATE TABLE "Iteration_REPLACE"."DiagramCanvas_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "DiagramCanvas_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "DiagramCanvasCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class DiagramElementThing (which derives from: DiagramElementContainer)
CREATE TABLE "Iteration_REPLACE"."DiagramElementThing" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DiagramElementThing_PK" PRIMARY KEY ("Iid")
);
-- Create table for class DiagramEdge (which derives from: DiagramElementThing)
CREATE TABLE "Iteration_REPLACE"."DiagramEdge" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DiagramEdge_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for DiagramEdge
CREATE TABLE "Iteration_REPLACE"."DiagramEdge_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "DiagramEdge_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for DiagramEdge
CREATE TABLE "Iteration_REPLACE"."DiagramEdge_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "DiagramEdge_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "DiagramEdgeCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Bounds (which derives from: DiagramThingBase)
CREATE TABLE "Iteration_REPLACE"."Bounds" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Bounds_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Bounds
CREATE TABLE "Iteration_REPLACE"."Bounds_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Bounds_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Bounds
CREATE TABLE "Iteration_REPLACE"."Bounds_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Bounds_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "BoundsCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class OwnedStyle (which derives from: DiagrammingStyle)
CREATE TABLE "Iteration_REPLACE"."OwnedStyle" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "OwnedStyle_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for OwnedStyle
CREATE TABLE "Iteration_REPLACE"."OwnedStyle_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "OwnedStyle_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for OwnedStyle
CREATE TABLE "Iteration_REPLACE"."OwnedStyle_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "OwnedStyle_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "OwnedStyleCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class Point (which derives from: DiagramThingBase)
CREATE TABLE "Iteration_REPLACE"."Point" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "Point_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for Point
CREATE TABLE "Iteration_REPLACE"."Point_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Point_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for Point
CREATE TABLE "Iteration_REPLACE"."Point_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "Point_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "PointCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- Create table for class DiagramShape (which derives from: DiagramElementThing)
CREATE TABLE "Iteration_REPLACE"."DiagramShape" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DiagramShape_PK" PRIMARY KEY ("Iid")
);
-- Create table for class DiagramObject (which derives from: DiagramShape)
CREATE TABLE "Iteration_REPLACE"."DiagramObject" (
  "Iid" uuid NOT NULL,
  "ValueTypeDictionary" hstore NOT NULL DEFAULT ''::hstore,
  CONSTRAINT "DiagramObject_PK" PRIMARY KEY ("Iid")
);
-- create revision-history table for DiagramObject
CREATE TABLE "Iteration_REPLACE"."DiagramObject_Revision" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Instant" timestamp without time zone NOT NULL,
  "Actor" uuid,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "DiagramObject_REV_PK" PRIMARY KEY ("Iid", "RevisionNumber")
);
-- create cache table for DiagramObject
CREATE TABLE "Iteration_REPLACE"."DiagramObject_Cache" (
  "Iid" uuid NOT NULL,
  "RevisionNumber" integer NOT NULL,
  "Jsonb" jsonb NOT NULL,
  CONSTRAINT "DiagramObject_CACHE_PK" PRIMARY KEY ("Iid"),
  CONSTRAINT "DiagramObjectCacheDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") MATCH SIMPLE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
-- ExcludedPerson is a collection property (many to many) of class Thing: [0..*]-[1..1]
CREATE TABLE "EngineeringModel_REPLACE"."Thing_ExcludedPerson" (
  "Thing" uuid NOT NULL,
  "ExcludedPerson" uuid NOT NULL,
  CONSTRAINT "Thing_ExcludedPerson_PK" PRIMARY KEY("Thing", "ExcludedPerson"),
  CONSTRAINT "Thing_ExcludedPerson_FK_Source" FOREIGN KEY ("Thing") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Thing_ExcludedPerson_FK_Target" FOREIGN KEY ("ExcludedPerson") REFERENCES "SiteDirectory"."Person" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."Thing_ExcludedPerson"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Thing_ExcludedPerson_ValidFrom" ON "EngineeringModel_REPLACE"."Thing_ExcludedPerson" ("ValidFrom");
CREATE INDEX "Idx_Thing_ExcludedPerson_ValidTo" ON "EngineeringModel_REPLACE"."Thing_ExcludedPerson" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Audit" (LIKE "EngineeringModel_REPLACE"."Thing_ExcludedPerson");
ALTER TABLE "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Thing_ExcludedPersonAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Audit" ("ValidFrom");
CREATE INDEX "Idx_Thing_ExcludedPersonAudit_ValidTo" ON "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Audit" ("ValidTo");

CREATE TRIGGER Thing_ExcludedPerson_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Thing_ExcludedPerson"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Thing_ExcludedPerson_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Thing_ExcludedPerson"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER thing_excludedperson_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Thing_ExcludedPerson"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Thing', 'EngineeringModel_REPLACE');
-- ExcludedDomain is a collection property (many to many) of class Thing: [0..*]-[1..1]
CREATE TABLE "EngineeringModel_REPLACE"."Thing_ExcludedDomain" (
  "Thing" uuid NOT NULL,
  "ExcludedDomain" uuid NOT NULL,
  CONSTRAINT "Thing_ExcludedDomain_PK" PRIMARY KEY("Thing", "ExcludedDomain"),
  CONSTRAINT "Thing_ExcludedDomain_FK_Source" FOREIGN KEY ("Thing") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Thing_ExcludedDomain_FK_Target" FOREIGN KEY ("ExcludedDomain") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."Thing_ExcludedDomain"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Thing_ExcludedDomain_ValidFrom" ON "EngineeringModel_REPLACE"."Thing_ExcludedDomain" ("ValidFrom");
CREATE INDEX "Idx_Thing_ExcludedDomain_ValidTo" ON "EngineeringModel_REPLACE"."Thing_ExcludedDomain" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Audit" (LIKE "EngineeringModel_REPLACE"."Thing_ExcludedDomain");
ALTER TABLE "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Thing_ExcludedDomainAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Audit" ("ValidFrom");
CREATE INDEX "Idx_Thing_ExcludedDomainAudit_ValidTo" ON "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Audit" ("ValidTo");

CREATE TRIGGER Thing_ExcludedDomain_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Thing_ExcludedDomain"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Thing_ExcludedDomain_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Thing_ExcludedDomain"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER thing_excludeddomain_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Thing_ExcludedDomain"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Thing', 'EngineeringModel_REPLACE');
-- Class TopContainer derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."TopContainer" ADD CONSTRAINT "TopContainerDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class EngineeringModel derives from TopContainer
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModel" ADD CONSTRAINT "EngineeringModelDerivesFromTopContainer" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."TopContainer" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- EngineeringModel.EngineeringModelSetup is an association to EngineeringModelSetup: [1..1]-[0..1]
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModel" ADD COLUMN "EngineeringModelSetup" uuid NOT NULL;
-- CommonFileStore is contained (composite) by EngineeringModel: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."CommonFileStore" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."CommonFileStore" ADD CONSTRAINT "CommonFileStore_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."EngineeringModel" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_CommonFileStore_Container" ON "EngineeringModel_REPLACE"."CommonFileStore" ("Container");
CREATE TRIGGER commonfilestore_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."CommonFileStore"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- ModelLogEntry is contained (composite) by EngineeringModel: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry" ADD CONSTRAINT "ModelLogEntry_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."EngineeringModel" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ModelLogEntry_Container" ON "EngineeringModel_REPLACE"."ModelLogEntry" ("Container");
CREATE TRIGGER modellogentry_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."ModelLogEntry"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Iteration is contained (composite) by EngineeringModel: [1..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Iteration" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Iteration" ADD CONSTRAINT "Iteration_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."EngineeringModel" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Iteration_Container" ON "EngineeringModel_REPLACE"."Iteration" ("Container");
CREATE TRIGGER iteration_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Iteration"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Book is contained (composite) by EngineeringModel: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Book" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Book" ADD CONSTRAINT "Book_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."EngineeringModel" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Book_Container" ON "EngineeringModel_REPLACE"."Book" ("Container");
ALTER TABLE "EngineeringModel_REPLACE"."Book" ADD COLUMN "Sequence" bigint NOT NULL;
CREATE TRIGGER book_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Book"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- EngineeringModelDataNote is contained (composite) by EngineeringModel: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataNote" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataNote" ADD CONSTRAINT "EngineeringModelDataNote_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."EngineeringModel" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_EngineeringModelDataNote_Container" ON "EngineeringModel_REPLACE"."EngineeringModelDataNote" ("Container");
CREATE TRIGGER engineeringmodeldatanote_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."EngineeringModelDataNote"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- ModellingAnnotationItem is contained (composite) by EngineeringModel: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem" ADD CONSTRAINT "ModellingAnnotationItem_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."EngineeringModel" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ModellingAnnotationItem_Container" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("Container");
CREATE TRIGGER modellingannotationitem_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."ModellingAnnotationItem"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Class FileStore derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."FileStore" ADD CONSTRAINT "FileStoreDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Folder is contained (composite) by FileStore: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Folder" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Folder" ADD CONSTRAINT "Folder_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."FileStore" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Folder_Container" ON "EngineeringModel_REPLACE"."Folder" ("Container");
CREATE TRIGGER folder_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Folder"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- File is contained (composite) by FileStore: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."File" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."File" ADD CONSTRAINT "File_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."FileStore" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_File_Container" ON "EngineeringModel_REPLACE"."File" ("Container");
CREATE TRIGGER file_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."File"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- FileStore.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."FileStore" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."FileStore" ADD CONSTRAINT "FileStore_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class CommonFileStore derives from FileStore
ALTER TABLE "EngineeringModel_REPLACE"."CommonFileStore" ADD CONSTRAINT "CommonFileStoreDerivesFromFileStore" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."FileStore" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Folder derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."Folder" ADD CONSTRAINT "FolderDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Folder.Creator is an association to Participant: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."Folder" ADD COLUMN "Creator" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Folder" ADD CONSTRAINT "Folder_FK_Creator" FOREIGN KEY ("Creator") REFERENCES "SiteDirectory"."Participant" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Folder.ContainingFolder is an optional association to Folder: [0..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."Folder" ADD COLUMN "ContainingFolder" uuid;
ALTER TABLE "EngineeringModel_REPLACE"."Folder" ADD CONSTRAINT "Folder_FK_ContainingFolder" FOREIGN KEY ("ContainingFolder") REFERENCES "EngineeringModel_REPLACE"."Folder" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Folder.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."Folder" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Folder" ADD CONSTRAINT "Folder_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class File derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."File" ADD CONSTRAINT "FileDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- File.LockedBy is an optional association to Person: [0..1]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."File" ADD COLUMN "LockedBy" uuid;
ALTER TABLE "EngineeringModel_REPLACE"."File" ADD CONSTRAINT "File_FK_LockedBy" FOREIGN KEY ("LockedBy") REFERENCES "SiteDirectory"."Person" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- FileRevision is contained (composite) by File: [1..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision" ADD CONSTRAINT "FileRevision_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."File" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_FileRevision_Container" ON "EngineeringModel_REPLACE"."FileRevision" ("Container");
CREATE TRIGGER filerevision_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."FileRevision"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- File.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."File" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."File" ADD CONSTRAINT "File_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Category is a collection property (many to many) of class File: [0..*]-[0..*]
CREATE TABLE "EngineeringModel_REPLACE"."File_Category" (
  "File" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "File_Category_PK" PRIMARY KEY("File", "Category"),
  CONSTRAINT "File_Category_FK_Source" FOREIGN KEY ("File") REFERENCES "EngineeringModel_REPLACE"."File" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "File_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."File_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_File_Category_ValidFrom" ON "EngineeringModel_REPLACE"."File_Category" ("ValidFrom");
CREATE INDEX "Idx_File_Category_ValidTo" ON "EngineeringModel_REPLACE"."File_Category" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."File_Category_Audit" (LIKE "EngineeringModel_REPLACE"."File_Category");
ALTER TABLE "EngineeringModel_REPLACE"."File_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_File_CategoryAudit_ValidFrom" ON "EngineeringModel_REPLACE"."File_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_File_CategoryAudit_ValidTo" ON "EngineeringModel_REPLACE"."File_Category_Audit" ("ValidTo");

CREATE TRIGGER File_Category_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."File_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER File_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."File_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER file_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."File_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('File', 'EngineeringModel_REPLACE');
-- Class FileRevision derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision" ADD CONSTRAINT "FileRevisionDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- FileRevision.Creator is an association to Participant: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision" ADD COLUMN "Creator" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision" ADD CONSTRAINT "FileRevision_FK_Creator" FOREIGN KEY ("Creator") REFERENCES "SiteDirectory"."Participant" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- FileRevision.ContainingFolder is an optional association to Folder: [0..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision" ADD COLUMN "ContainingFolder" uuid;
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision" ADD CONSTRAINT "FileRevision_FK_ContainingFolder" FOREIGN KEY ("ContainingFolder") REFERENCES "EngineeringModel_REPLACE"."Folder" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- FileType is an ordered collection property (many to many) of class FileRevision: [1..*]-[0..*] (ordered)
CREATE TABLE "EngineeringModel_REPLACE"."FileRevision_FileType" (
  "FileRevision" uuid NOT NULL,
  "FileType" uuid NOT NULL,
  "Sequence" bigint NOT NULL,
  CONSTRAINT "FileRevision_FileType_PK" PRIMARY KEY("FileRevision", "FileType"),
  CONSTRAINT "FileRevision_FileType_FK_Source" FOREIGN KEY ("FileRevision") REFERENCES "EngineeringModel_REPLACE"."FileRevision" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "FileRevision_FileType_FK_Target" FOREIGN KEY ("FileType") REFERENCES "SiteDirectory"."FileType" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision_FileType"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_FileRevision_FileType_ValidFrom" ON "EngineeringModel_REPLACE"."FileRevision_FileType" ("ValidFrom");
CREATE INDEX "Idx_FileRevision_FileType_ValidTo" ON "EngineeringModel_REPLACE"."FileRevision_FileType" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."FileRevision_FileType_Audit" (LIKE "EngineeringModel_REPLACE"."FileRevision_FileType");
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision_FileType_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_FileRevision_FileTypeAudit_ValidFrom" ON "EngineeringModel_REPLACE"."FileRevision_FileType_Audit" ("ValidFrom");
CREATE INDEX "Idx_FileRevision_FileTypeAudit_ValidTo" ON "EngineeringModel_REPLACE"."FileRevision_FileType_Audit" ("ValidTo");

CREATE TRIGGER FileRevision_FileType_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."FileRevision_FileType"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER FileRevision_FileType_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."FileRevision_FileType"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER filerevision_filetype_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."FileRevision_FileType"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('FileRevision', 'EngineeringModel_REPLACE');
-- Class ModelLogEntry derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry" ADD CONSTRAINT "ModelLogEntryDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Category is a collection property (many to many) of class ModelLogEntry: [0..*]-[0..*]
CREATE TABLE "EngineeringModel_REPLACE"."ModelLogEntry_Category" (
  "ModelLogEntry" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "ModelLogEntry_Category_PK" PRIMARY KEY("ModelLogEntry", "Category"),
  CONSTRAINT "ModelLogEntry_Category_FK_Source" FOREIGN KEY ("ModelLogEntry") REFERENCES "EngineeringModel_REPLACE"."ModelLogEntry" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ModelLogEntry_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ModelLogEntry_Category_ValidFrom" ON "EngineeringModel_REPLACE"."ModelLogEntry_Category" ("ValidFrom");
CREATE INDEX "Idx_ModelLogEntry_Category_ValidTo" ON "EngineeringModel_REPLACE"."ModelLogEntry_Category" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ModelLogEntry_Category_Audit" (LIKE "EngineeringModel_REPLACE"."ModelLogEntry_Category");
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ModelLogEntry_CategoryAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ModelLogEntry_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_ModelLogEntry_CategoryAudit_ValidTo" ON "EngineeringModel_REPLACE"."ModelLogEntry_Category_Audit" ("ValidTo");

CREATE TRIGGER ModelLogEntry_Category_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ModelLogEntry_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ModelLogEntry_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ModelLogEntry_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER modellogentry_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."ModelLogEntry_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ModelLogEntry', 'EngineeringModel_REPLACE');
-- ModelLogEntry.Author is an optional association to Person: [0..1]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry" ADD COLUMN "Author" uuid;
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry" ADD CONSTRAINT "ModelLogEntry_FK_Author" FOREIGN KEY ("Author") REFERENCES "SiteDirectory"."Person" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- AffectedItemIid is a collection property of class ModelLogEntry: [0..*]
CREATE TABLE "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid" (
  "ModelLogEntry" uuid NOT NULL,
  "AffectedItemIid" uuid NOT NULL,
  CONSTRAINT "ModelLogEntry_AffectedItemIid_PK" PRIMARY KEY("ModelLogEntry","AffectedItemIid"),
  CONSTRAINT "ModelLogEntry_AffectedItemIid_FK_Source" FOREIGN KEY ("ModelLogEntry") REFERENCES "EngineeringModel_REPLACE"."ModelLogEntry" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ModelLogEntry_AffectedItemIid_ValidFrom" ON "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid" ("ValidFrom");
CREATE INDEX "Idx_ModelLogEntry_AffectedItemIid_ValidTo" ON "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid_Audit" (LIKE "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid");
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ModelLogEntry_AffectedItemIidAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid_Audit" ("ValidFrom");
CREATE INDEX "Idx_ModelLogEntry_AffectedItemIidAudit_ValidTo" ON "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid_Audit" ("ValidTo");

CREATE TRIGGER ModelLogEntry_AffectedItemIid_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ModelLogEntry_AffectedItemIid_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER modellogentry_affecteditemiid_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ModelLogEntry', 'EngineeringModel_REPLACE');
-- Class Iteration derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."Iteration" ADD CONSTRAINT "IterationDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Iteration.IterationSetup is an association to IterationSetup: [1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Iteration" ADD COLUMN "IterationSetup" uuid NOT NULL;
-- Option is contained (composite) by Iteration: [1..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Option" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Option" ADD CONSTRAINT "Option_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Option_Container" ON "Iteration_REPLACE"."Option" ("Container");
ALTER TABLE "Iteration_REPLACE"."Option" ADD COLUMN "Sequence" bigint NOT NULL;
CREATE TRIGGER option_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Option"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Publication is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Publication" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Publication" ADD CONSTRAINT "Publication_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Publication_Container" ON "Iteration_REPLACE"."Publication" ("Container");
CREATE TRIGGER publication_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Publication"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- PossibleFiniteStateList is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList" ADD CONSTRAINT "PossibleFiniteStateList_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_PossibleFiniteStateList_Container" ON "Iteration_REPLACE"."PossibleFiniteStateList" ("Container");
CREATE TRIGGER possiblefinitestatelist_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."PossibleFiniteStateList"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Iteration.TopElement is an optional association to ElementDefinition: [0..1]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Iteration" ADD COLUMN "TopElement" uuid;
-- ElementDefinition is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ElementDefinition" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ElementDefinition" ADD CONSTRAINT "ElementDefinition_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ElementDefinition_Container" ON "Iteration_REPLACE"."ElementDefinition" ("Container");
CREATE TRIGGER elementdefinition_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ElementDefinition"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Relationship is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Relationship" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Relationship" ADD CONSTRAINT "Relationship_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Relationship_Container" ON "Iteration_REPLACE"."Relationship" ("Container");
CREATE TRIGGER relationship_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Relationship"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- ExternalIdentifierMap is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ExternalIdentifierMap" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ExternalIdentifierMap" ADD CONSTRAINT "ExternalIdentifierMap_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ExternalIdentifierMap_Container" ON "Iteration_REPLACE"."ExternalIdentifierMap" ("Container");
CREATE TRIGGER externalidentifiermap_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ExternalIdentifierMap"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- RequirementsSpecification is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."RequirementsSpecification" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."RequirementsSpecification" ADD CONSTRAINT "RequirementsSpecification_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_RequirementsSpecification_Container" ON "Iteration_REPLACE"."RequirementsSpecification" ("Container");
CREATE TRIGGER requirementsspecification_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."RequirementsSpecification"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- DomainFileStore is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."DomainFileStore" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."DomainFileStore" ADD CONSTRAINT "DomainFileStore_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_DomainFileStore_Container" ON "Iteration_REPLACE"."DomainFileStore" ("Container");
CREATE TRIGGER domainfilestore_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."DomainFileStore"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- ActualFiniteStateList is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList" ADD CONSTRAINT "ActualFiniteStateList_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ActualFiniteStateList_Container" ON "Iteration_REPLACE"."ActualFiniteStateList" ("Container");
CREATE TRIGGER actualfinitestatelist_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ActualFiniteStateList"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Iteration.DefaultOption is an optional association to Option: [0..1]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Iteration" ADD COLUMN "DefaultOption" uuid;
-- RuleVerificationList is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."RuleVerificationList" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."RuleVerificationList" ADD CONSTRAINT "RuleVerificationList_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_RuleVerificationList_Container" ON "Iteration_REPLACE"."RuleVerificationList" ("Container");
CREATE TRIGGER ruleverificationlist_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."RuleVerificationList"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Stakeholder is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Stakeholder" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Stakeholder" ADD CONSTRAINT "Stakeholder_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Stakeholder_Container" ON "Iteration_REPLACE"."Stakeholder" ("Container");
CREATE TRIGGER stakeholder_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Stakeholder"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Goal is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Goal" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Goal" ADD CONSTRAINT "Goal_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Goal_Container" ON "Iteration_REPLACE"."Goal" ("Container");
CREATE TRIGGER goal_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Goal"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- ValueGroup is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ValueGroup" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ValueGroup" ADD CONSTRAINT "ValueGroup_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ValueGroup_Container" ON "Iteration_REPLACE"."ValueGroup" ("Container");
CREATE TRIGGER valuegroup_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ValueGroup"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- StakeholderValue is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."StakeholderValue" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."StakeholderValue" ADD CONSTRAINT "StakeholderValue_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_StakeholderValue_Container" ON "Iteration_REPLACE"."StakeholderValue" ("Container");
CREATE TRIGGER stakeholdervalue_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."StakeholderValue"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- StakeHolderValueMap is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap" ADD CONSTRAINT "StakeHolderValueMap_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_StakeHolderValueMap_Container" ON "Iteration_REPLACE"."StakeHolderValueMap" ("Container");
CREATE TRIGGER stakeholdervaluemap_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."StakeHolderValueMap"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- SharedStyle is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."SharedStyle" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."SharedStyle" ADD CONSTRAINT "SharedStyle_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_SharedStyle_Container" ON "Iteration_REPLACE"."SharedStyle" ("Container");
CREATE TRIGGER sharedstyle_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."SharedStyle"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- DiagramCanvas is contained (composite) by Iteration: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."DiagramCanvas" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."DiagramCanvas" ADD CONSTRAINT "DiagramCanvas_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Iteration" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_DiagramCanvas_Container" ON "Iteration_REPLACE"."DiagramCanvas" ("Container");
CREATE TRIGGER diagramcanvas_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."DiagramCanvas"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Class Book derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."Book" ADD CONSTRAINT "BookDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Section is contained (composite) by Book: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Section" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Section" ADD CONSTRAINT "Section_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Book" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Section_Container" ON "EngineeringModel_REPLACE"."Section" ("Container");
ALTER TABLE "EngineeringModel_REPLACE"."Section" ADD COLUMN "Sequence" bigint NOT NULL;
CREATE TRIGGER section_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Section"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Category is a collection property (many to many) of class Book: [0..*]-[0..*]
CREATE TABLE "EngineeringModel_REPLACE"."Book_Category" (
  "Book" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "Book_Category_PK" PRIMARY KEY("Book", "Category"),
  CONSTRAINT "Book_Category_FK_Source" FOREIGN KEY ("Book") REFERENCES "EngineeringModel_REPLACE"."Book" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Book_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."Book_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Book_Category_ValidFrom" ON "EngineeringModel_REPLACE"."Book_Category" ("ValidFrom");
CREATE INDEX "Idx_Book_Category_ValidTo" ON "EngineeringModel_REPLACE"."Book_Category" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Book_Category_Audit" (LIKE "EngineeringModel_REPLACE"."Book_Category");
ALTER TABLE "EngineeringModel_REPLACE"."Book_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Book_CategoryAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Book_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_Book_CategoryAudit_ValidTo" ON "EngineeringModel_REPLACE"."Book_Category_Audit" ("ValidTo");

CREATE TRIGGER Book_Category_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Book_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Book_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Book_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER book_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Book_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Book', 'EngineeringModel_REPLACE');
-- Book.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."Book" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Book" ADD CONSTRAINT "Book_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Section derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."Section" ADD CONSTRAINT "SectionDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Page is contained (composite) by Section: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Page" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Page" ADD CONSTRAINT "Page_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Section" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Page_Container" ON "EngineeringModel_REPLACE"."Page" ("Container");
ALTER TABLE "EngineeringModel_REPLACE"."Page" ADD COLUMN "Sequence" bigint NOT NULL;
CREATE TRIGGER page_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Page"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Category is a collection property (many to many) of class Section: [0..*]-[0..*]
CREATE TABLE "EngineeringModel_REPLACE"."Section_Category" (
  "Section" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "Section_Category_PK" PRIMARY KEY("Section", "Category"),
  CONSTRAINT "Section_Category_FK_Source" FOREIGN KEY ("Section") REFERENCES "EngineeringModel_REPLACE"."Section" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Section_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."Section_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Section_Category_ValidFrom" ON "EngineeringModel_REPLACE"."Section_Category" ("ValidFrom");
CREATE INDEX "Idx_Section_Category_ValidTo" ON "EngineeringModel_REPLACE"."Section_Category" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Section_Category_Audit" (LIKE "EngineeringModel_REPLACE"."Section_Category");
ALTER TABLE "EngineeringModel_REPLACE"."Section_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Section_CategoryAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Section_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_Section_CategoryAudit_ValidTo" ON "EngineeringModel_REPLACE"."Section_Category_Audit" ("ValidTo");

CREATE TRIGGER Section_Category_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Section_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Section_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Section_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER section_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Section_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Section', 'EngineeringModel_REPLACE');
-- Section.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."Section" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Section" ADD CONSTRAINT "Section_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Page derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."Page" ADD CONSTRAINT "PageDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Note is contained (composite) by Page: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Note" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Note" ADD CONSTRAINT "Note_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."Page" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Note_Container" ON "EngineeringModel_REPLACE"."Note" ("Container");
ALTER TABLE "EngineeringModel_REPLACE"."Note" ADD COLUMN "Sequence" bigint NOT NULL;
CREATE TRIGGER note_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Note"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Category is a collection property (many to many) of class Page: [0..*]-[0..*]
CREATE TABLE "EngineeringModel_REPLACE"."Page_Category" (
  "Page" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "Page_Category_PK" PRIMARY KEY("Page", "Category"),
  CONSTRAINT "Page_Category_FK_Source" FOREIGN KEY ("Page") REFERENCES "EngineeringModel_REPLACE"."Page" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Page_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."Page_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Page_Category_ValidFrom" ON "EngineeringModel_REPLACE"."Page_Category" ("ValidFrom");
CREATE INDEX "Idx_Page_Category_ValidTo" ON "EngineeringModel_REPLACE"."Page_Category" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Page_Category_Audit" (LIKE "EngineeringModel_REPLACE"."Page_Category");
ALTER TABLE "EngineeringModel_REPLACE"."Page_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Page_CategoryAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Page_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_Page_CategoryAudit_ValidTo" ON "EngineeringModel_REPLACE"."Page_Category_Audit" ("ValidTo");

CREATE TRIGGER Page_Category_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Page_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Page_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Page_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER page_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Page_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Page', 'EngineeringModel_REPLACE');
-- Page.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."Page" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Page" ADD CONSTRAINT "Page_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Note derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."Note" ADD CONSTRAINT "NoteDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Category is a collection property (many to many) of class Note: [0..*]-[0..*]
CREATE TABLE "EngineeringModel_REPLACE"."Note_Category" (
  "Note" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "Note_Category_PK" PRIMARY KEY("Note", "Category"),
  CONSTRAINT "Note_Category_FK_Source" FOREIGN KEY ("Note") REFERENCES "EngineeringModel_REPLACE"."Note" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Note_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."Note_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Note_Category_ValidFrom" ON "EngineeringModel_REPLACE"."Note_Category" ("ValidFrom");
CREATE INDEX "Idx_Note_Category_ValidTo" ON "EngineeringModel_REPLACE"."Note_Category" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Note_Category_Audit" (LIKE "EngineeringModel_REPLACE"."Note_Category");
ALTER TABLE "EngineeringModel_REPLACE"."Note_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Note_CategoryAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Note_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_Note_CategoryAudit_ValidTo" ON "EngineeringModel_REPLACE"."Note_Category_Audit" ("ValidTo");

CREATE TRIGGER Note_Category_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Note_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Note_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Note_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER note_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Note_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Note', 'EngineeringModel_REPLACE');
-- Note.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."Note" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Note" ADD CONSTRAINT "Note_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class BinaryNote derives from Note
ALTER TABLE "EngineeringModel_REPLACE"."BinaryNote" ADD CONSTRAINT "BinaryNoteDerivesFromNote" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Note" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- BinaryNote.FileType is an association to FileType: [1..1]
ALTER TABLE "EngineeringModel_REPLACE"."BinaryNote" ADD COLUMN "FileType" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."BinaryNote" ADD CONSTRAINT "BinaryNote_FK_FileType" FOREIGN KEY ("FileType") REFERENCES "SiteDirectory"."FileType" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class TextualNote derives from Note
ALTER TABLE "EngineeringModel_REPLACE"."TextualNote" ADD CONSTRAINT "TextualNoteDerivesFromNote" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Note" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class GenericAnnotation derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."GenericAnnotation" ADD CONSTRAINT "GenericAnnotationDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class EngineeringModelDataAnnotation derives from GenericAnnotation
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ADD CONSTRAINT "EngineeringModelDataAnnotationDerivesFromGenericAnnotation" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."GenericAnnotation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ModellingThingReference is contained (composite) by EngineeringModelDataAnnotation: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."ModellingThingReference" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."ModellingThingReference" ADD CONSTRAINT "ModellingThingReference_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ModellingThingReference_Container" ON "EngineeringModel_REPLACE"."ModellingThingReference" ("Container");
CREATE TRIGGER modellingthingreference_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."ModellingThingReference"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- EngineeringModelDataAnnotation.Author is an association to Participant: [1..1]
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ADD COLUMN "Author" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ADD CONSTRAINT "EngineeringModelDataAnnotation_FK_Author" FOREIGN KEY ("Author") REFERENCES "SiteDirectory"."Participant" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- EngineeringModelDataAnnotation.PrimaryAnnotatedThing is an optional association to ModellingThingReference: [0..1]
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ADD COLUMN "PrimaryAnnotatedThing" uuid;
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ADD CONSTRAINT "EngineeringModelDataAnnotation_FK_PrimaryAnnotatedThing" FOREIGN KEY ("PrimaryAnnotatedThing") REFERENCES "EngineeringModel_REPLACE"."ModellingThingReference" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- EngineeringModelDataDiscussionItem is contained (composite) by EngineeringModelDataAnnotation: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem" ADD CONSTRAINT "EngineeringModelDataDiscussionItem_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_EngineeringModelDataDiscussionItem_Container" ON "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem" ("Container");
CREATE TRIGGER engineeringmodeldatadiscussionitem_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Class EngineeringModelDataNote derives from EngineeringModelDataAnnotation
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataNote" ADD CONSTRAINT "EngineeringModelDataNoteDerivesFromEngineeringModelDataAnnotation" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ThingReference derives from Thing
ALTER TABLE "EngineeringModel_REPLACE"."ThingReference" ADD CONSTRAINT "ThingReferenceDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ThingReference.ReferencedThing is an association to Thing: [1..1]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."ThingReference" ADD COLUMN "ReferencedThing" uuid NOT NULL;
-- Class ModellingThingReference derives from ThingReference
ALTER TABLE "EngineeringModel_REPLACE"."ModellingThingReference" ADD CONSTRAINT "ModellingThingReferenceDerivesFromThingReference" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."ThingReference" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class DiscussionItem derives from GenericAnnotation
ALTER TABLE "EngineeringModel_REPLACE"."DiscussionItem" ADD CONSTRAINT "DiscussionItemDerivesFromGenericAnnotation" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."GenericAnnotation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- DiscussionItem.ReplyTo is an optional association to DiscussionItem: [0..1]
ALTER TABLE "EngineeringModel_REPLACE"."DiscussionItem" ADD COLUMN "ReplyTo" uuid;
ALTER TABLE "EngineeringModel_REPLACE"."DiscussionItem" ADD CONSTRAINT "DiscussionItem_FK_ReplyTo" FOREIGN KEY ("ReplyTo") REFERENCES "EngineeringModel_REPLACE"."DiscussionItem" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Class EngineeringModelDataDiscussionItem derives from DiscussionItem
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem" ADD CONSTRAINT "EngineeringModelDataDiscussionItemDerivesFromDiscussionItem" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."DiscussionItem" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- EngineeringModelDataDiscussionItem.Author is an association to Participant: [1..1]
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem" ADD COLUMN "Author" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem" ADD CONSTRAINT "EngineeringModelDataDiscussionItem_FK_Author" FOREIGN KEY ("Author") REFERENCES "SiteDirectory"."Participant" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ModellingAnnotationItem derives from EngineeringModelDataAnnotation
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem" ADD CONSTRAINT "ModellingAnnotationItemDerivesFromEngineeringModelDataAnnotation" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Approval is contained (composite) by ModellingAnnotationItem: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Approval" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Approval" ADD CONSTRAINT "Approval_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Approval_Container" ON "EngineeringModel_REPLACE"."Approval" ("Container");
CREATE TRIGGER approval_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Approval"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- SourceAnnotation is a collection property (many to many) of class ModellingAnnotationItem: [0..*]-[1..1]
CREATE TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation" (
  "ModellingAnnotationItem" uuid NOT NULL,
  "SourceAnnotation" uuid NOT NULL,
  CONSTRAINT "ModellingAnnotationItem_SourceAnnotation_PK" PRIMARY KEY("ModellingAnnotationItem", "SourceAnnotation"),
  CONSTRAINT "ModellingAnnotationItem_SourceAnnotation_FK_Source" FOREIGN KEY ("ModellingAnnotationItem") REFERENCES "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ModellingAnnotationItem_SourceAnnotation_FK_Target" FOREIGN KEY ("SourceAnnotation") REFERENCES "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ModellingAnnotationItem_SourceAnnotation_ValidFrom" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation" ("ValidFrom");
CREATE INDEX "Idx_ModellingAnnotationItem_SourceAnnotation_ValidTo" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Audit" (LIKE "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation");
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ModellingAnnotationItem_SourceAnnotationAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Audit" ("ValidFrom");
CREATE INDEX "Idx_ModellingAnnotationItem_SourceAnnotationAudit_ValidTo" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Audit" ("ValidTo");

CREATE TRIGGER ModellingAnnotationItem_SourceAnnotation_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ModellingAnnotationItem_SourceAnnotation_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER modellingannotationitem_sourceannotation_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ModellingAnnotationItem', 'EngineeringModel_REPLACE');
-- ModellingAnnotationItem.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem" ADD CONSTRAINT "ModellingAnnotationItem_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Category is a collection property (many to many) of class ModellingAnnotationItem: [0..*]-[0..*]
CREATE TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category" (
  "ModellingAnnotationItem" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "ModellingAnnotationItem_Category_PK" PRIMARY KEY("ModellingAnnotationItem", "Category"),
  CONSTRAINT "ModellingAnnotationItem_Category_FK_Source" FOREIGN KEY ("ModellingAnnotationItem") REFERENCES "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ModellingAnnotationItem_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ModellingAnnotationItem_Category_ValidFrom" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category" ("ValidFrom");
CREATE INDEX "Idx_ModellingAnnotationItem_Category_ValidTo" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Audit" (LIKE "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category");
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ModellingAnnotationItem_CategoryAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_ModellingAnnotationItem_CategoryAudit_ValidTo" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Audit" ("ValidTo");

CREATE TRIGGER ModellingAnnotationItem_Category_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ModellingAnnotationItem_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER modellingannotationitem_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ModellingAnnotationItem', 'EngineeringModel_REPLACE');
-- Class ContractDeviation derives from ModellingAnnotationItem
ALTER TABLE "EngineeringModel_REPLACE"."ContractDeviation" ADD CONSTRAINT "ContractDeviationDerivesFromModellingAnnotationItem" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class RequestForWaiver derives from ContractDeviation
ALTER TABLE "EngineeringModel_REPLACE"."RequestForWaiver" ADD CONSTRAINT "RequestForWaiverDerivesFromContractDeviation" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."ContractDeviation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Approval derives from GenericAnnotation
ALTER TABLE "EngineeringModel_REPLACE"."Approval" ADD CONSTRAINT "ApprovalDerivesFromGenericAnnotation" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."GenericAnnotation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Approval.Author is an association to Participant: [1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Approval" ADD COLUMN "Author" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Approval" ADD CONSTRAINT "Approval_FK_Author" FOREIGN KEY ("Author") REFERENCES "SiteDirectory"."Participant" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Approval.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."Approval" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Approval" ADD CONSTRAINT "Approval_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class RequestForDeviation derives from ContractDeviation
ALTER TABLE "EngineeringModel_REPLACE"."RequestForDeviation" ADD CONSTRAINT "RequestForDeviationDerivesFromContractDeviation" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."ContractDeviation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ChangeRequest derives from ContractDeviation
ALTER TABLE "EngineeringModel_REPLACE"."ChangeRequest" ADD CONSTRAINT "ChangeRequestDerivesFromContractDeviation" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."ContractDeviation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ReviewItemDiscrepancy derives from ModellingAnnotationItem
ALTER TABLE "EngineeringModel_REPLACE"."ReviewItemDiscrepancy" ADD CONSTRAINT "ReviewItemDiscrepancyDerivesFromModellingAnnotationItem" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Solution is contained (composite) by ReviewItemDiscrepancy: [0..*]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Solution" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Solution" ADD CONSTRAINT "Solution_FK_Container" FOREIGN KEY ("Container") REFERENCES "EngineeringModel_REPLACE"."ReviewItemDiscrepancy" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Solution_Container" ON "EngineeringModel_REPLACE"."Solution" ("Container");
CREATE TRIGGER solution_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "EngineeringModel_REPLACE"."Solution"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'EngineeringModel_REPLACE');
-- Class Solution derives from GenericAnnotation
ALTER TABLE "EngineeringModel_REPLACE"."Solution" ADD CONSTRAINT "SolutionDerivesFromGenericAnnotation" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."GenericAnnotation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Solution.Author is an association to Participant: [1..1]
ALTER TABLE "EngineeringModel_REPLACE"."Solution" ADD COLUMN "Author" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Solution" ADD CONSTRAINT "Solution_FK_Author" FOREIGN KEY ("Author") REFERENCES "SiteDirectory"."Participant" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Solution.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "EngineeringModel_REPLACE"."Solution" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."Solution" ADD CONSTRAINT "Solution_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ActionItem derives from ModellingAnnotationItem
ALTER TABLE "EngineeringModel_REPLACE"."ActionItem" ADD CONSTRAINT "ActionItemDerivesFromModellingAnnotationItem" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ActionItem.Actionee is an association to Participant: [1..1]
ALTER TABLE "EngineeringModel_REPLACE"."ActionItem" ADD COLUMN "Actionee" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."ActionItem" ADD CONSTRAINT "ActionItem_FK_Actionee" FOREIGN KEY ("Actionee") REFERENCES "SiteDirectory"."Participant" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ChangeProposal derives from ModellingAnnotationItem
ALTER TABLE "EngineeringModel_REPLACE"."ChangeProposal" ADD CONSTRAINT "ChangeProposalDerivesFromModellingAnnotationItem" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ChangeProposal.ChangeRequest is an association to ChangeRequest: [1..1]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."ChangeProposal" ADD COLUMN "ChangeRequest" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."ChangeProposal" ADD CONSTRAINT "ChangeProposal_FK_ChangeRequest" FOREIGN KEY ("ChangeRequest") REFERENCES "EngineeringModel_REPLACE"."ChangeRequest" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ContractChangeNotice derives from ModellingAnnotationItem
ALTER TABLE "EngineeringModel_REPLACE"."ContractChangeNotice" ADD CONSTRAINT "ContractChangeNoticeDerivesFromModellingAnnotationItem" FOREIGN KEY ("Iid") REFERENCES "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ContractChangeNotice.ChangeProposal is an association to ChangeProposal: [1..1]-[1..1]
ALTER TABLE "EngineeringModel_REPLACE"."ContractChangeNotice" ADD COLUMN "ChangeProposal" uuid NOT NULL;
ALTER TABLE "EngineeringModel_REPLACE"."ContractChangeNotice" ADD CONSTRAINT "ContractChangeNotice_FK_ChangeProposal" FOREIGN KEY ("ChangeProposal") REFERENCES "EngineeringModel_REPLACE"."ChangeProposal" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ExcludedPerson is a collection property (many to many) of class Thing: [0..*]-[1..1]
CREATE TABLE "Iteration_REPLACE"."Thing_ExcludedPerson" (
  "Thing" uuid NOT NULL,
  "ExcludedPerson" uuid NOT NULL,
  CONSTRAINT "Thing_ExcludedPerson_PK" PRIMARY KEY("Thing", "ExcludedPerson"),
  CONSTRAINT "Thing_ExcludedPerson_FK_Source" FOREIGN KEY ("Thing") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Thing_ExcludedPerson_FK_Target" FOREIGN KEY ("ExcludedPerson") REFERENCES "SiteDirectory"."Person" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."Thing_ExcludedPerson"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Thing_ExcludedPerson_ValidFrom" ON "Iteration_REPLACE"."Thing_ExcludedPerson" ("ValidFrom");
CREATE INDEX "Idx_Thing_ExcludedPerson_ValidTo" ON "Iteration_REPLACE"."Thing_ExcludedPerson" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Thing_ExcludedPerson_Audit" (LIKE "Iteration_REPLACE"."Thing_ExcludedPerson");
ALTER TABLE "Iteration_REPLACE"."Thing_ExcludedPerson_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Thing_ExcludedPersonAudit_ValidFrom" ON "Iteration_REPLACE"."Thing_ExcludedPerson_Audit" ("ValidFrom");
CREATE INDEX "Idx_Thing_ExcludedPersonAudit_ValidTo" ON "Iteration_REPLACE"."Thing_ExcludedPerson_Audit" ("ValidTo");

CREATE TRIGGER Thing_ExcludedPerson_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Thing_ExcludedPerson"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Thing_ExcludedPerson_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Thing_ExcludedPerson"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER thing_excludedperson_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Thing_ExcludedPerson"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Thing', 'EngineeringModel_REPLACE');
-- ExcludedDomain is a collection property (many to many) of class Thing: [0..*]-[1..1]
CREATE TABLE "Iteration_REPLACE"."Thing_ExcludedDomain" (
  "Thing" uuid NOT NULL,
  "ExcludedDomain" uuid NOT NULL,
  CONSTRAINT "Thing_ExcludedDomain_PK" PRIMARY KEY("Thing", "ExcludedDomain"),
  CONSTRAINT "Thing_ExcludedDomain_FK_Source" FOREIGN KEY ("Thing") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Thing_ExcludedDomain_FK_Target" FOREIGN KEY ("ExcludedDomain") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."Thing_ExcludedDomain"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Thing_ExcludedDomain_ValidFrom" ON "Iteration_REPLACE"."Thing_ExcludedDomain" ("ValidFrom");
CREATE INDEX "Idx_Thing_ExcludedDomain_ValidTo" ON "Iteration_REPLACE"."Thing_ExcludedDomain" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Thing_ExcludedDomain_Audit" (LIKE "Iteration_REPLACE"."Thing_ExcludedDomain");
ALTER TABLE "Iteration_REPLACE"."Thing_ExcludedDomain_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Thing_ExcludedDomainAudit_ValidFrom" ON "Iteration_REPLACE"."Thing_ExcludedDomain_Audit" ("ValidFrom");
CREATE INDEX "Idx_Thing_ExcludedDomainAudit_ValidTo" ON "Iteration_REPLACE"."Thing_ExcludedDomain_Audit" ("ValidTo");

CREATE TRIGGER Thing_ExcludedDomain_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Thing_ExcludedDomain"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Thing_ExcludedDomain_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Thing_ExcludedDomain"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER thing_excludeddomain_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Thing_ExcludedDomain"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Thing', 'EngineeringModel_REPLACE');
-- Class DefinedThing derives from Thing
ALTER TABLE "Iteration_REPLACE"."DefinedThing" ADD CONSTRAINT "DefinedThingDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Alias is contained (composite) by DefinedThing: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Alias" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Alias" ADD CONSTRAINT "Alias_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Alias_Container" ON "Iteration_REPLACE"."Alias" ("Container");
CREATE TRIGGER alias_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Alias"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Definition is contained (composite) by DefinedThing: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Definition" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Definition" ADD CONSTRAINT "Definition_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Definition_Container" ON "Iteration_REPLACE"."Definition" ("Container");
CREATE TRIGGER definition_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Definition"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- HyperLink is contained (composite) by DefinedThing: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."HyperLink" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."HyperLink" ADD CONSTRAINT "HyperLink_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_HyperLink_Container" ON "Iteration_REPLACE"."HyperLink" ("Container");
CREATE TRIGGER hyperlink_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."HyperLink"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class Option derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."Option" ADD CONSTRAINT "OptionDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- NestedElement is contained (composite) by Option: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."NestedElement" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."NestedElement" ADD CONSTRAINT "NestedElement_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."Option" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_NestedElement_Container" ON "Iteration_REPLACE"."NestedElement" ("Container");
CREATE TRIGGER nestedelement_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."NestedElement"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Category is a collection property (many to many) of class Option: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."Option_Category" (
  "Option" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "Option_Category_PK" PRIMARY KEY("Option", "Category"),
  CONSTRAINT "Option_Category_FK_Source" FOREIGN KEY ("Option") REFERENCES "Iteration_REPLACE"."Option" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Option_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."Option_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Option_Category_ValidFrom" ON "Iteration_REPLACE"."Option_Category" ("ValidFrom");
CREATE INDEX "Idx_Option_Category_ValidTo" ON "Iteration_REPLACE"."Option_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Option_Category_Audit" (LIKE "Iteration_REPLACE"."Option_Category");
ALTER TABLE "Iteration_REPLACE"."Option_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Option_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."Option_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_Option_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."Option_Category_Audit" ("ValidTo");

CREATE TRIGGER Option_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Option_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Option_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Option_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER option_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Option_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Option', 'EngineeringModel_REPLACE');
-- Class Alias derives from Thing
ALTER TABLE "Iteration_REPLACE"."Alias" ADD CONSTRAINT "AliasDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Definition derives from Thing
ALTER TABLE "Iteration_REPLACE"."Definition" ADD CONSTRAINT "DefinitionDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Citation is contained (composite) by Definition: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Citation" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Citation" ADD CONSTRAINT "Citation_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."Definition" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Citation_Container" ON "Iteration_REPLACE"."Citation" ("Container");
CREATE TRIGGER citation_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Citation"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Note is an ordered collection property of class Definition: [0..*] (ordered)
CREATE TABLE "Iteration_REPLACE"."Definition_Note" (
  "Definition" uuid NOT NULL,
  "Note" text NOT NULL,
  "Sequence" bigint NOT NULL,
  CONSTRAINT "Definition_Note_PK" PRIMARY KEY("Definition","Note"),
  CONSTRAINT "Definition_Note_FK_Source" FOREIGN KEY ("Definition") REFERENCES "Iteration_REPLACE"."Definition" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
ALTER TABLE "Iteration_REPLACE"."Definition_Note"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Definition_Note_ValidFrom" ON "Iteration_REPLACE"."Definition_Note" ("ValidFrom");
CREATE INDEX "Idx_Definition_Note_ValidTo" ON "Iteration_REPLACE"."Definition_Note" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Definition_Note_Audit" (LIKE "Iteration_REPLACE"."Definition_Note");
ALTER TABLE "Iteration_REPLACE"."Definition_Note_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Definition_NoteAudit_ValidFrom" ON "Iteration_REPLACE"."Definition_Note_Audit" ("ValidFrom");
CREATE INDEX "Idx_Definition_NoteAudit_ValidTo" ON "Iteration_REPLACE"."Definition_Note_Audit" ("ValidTo");

CREATE TRIGGER Definition_Note_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Definition_Note"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Definition_Note_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Definition_Note"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER definition_note_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Definition_Note"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Definition', 'EngineeringModel_REPLACE');
-- Example is an ordered collection property of class Definition: [0..*] (ordered)
CREATE TABLE "Iteration_REPLACE"."Definition_Example" (
  "Definition" uuid NOT NULL,
  "Example" text NOT NULL,
  "Sequence" bigint NOT NULL,
  CONSTRAINT "Definition_Example_PK" PRIMARY KEY("Definition","Example"),
  CONSTRAINT "Definition_Example_FK_Source" FOREIGN KEY ("Definition") REFERENCES "Iteration_REPLACE"."Definition" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
ALTER TABLE "Iteration_REPLACE"."Definition_Example"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Definition_Example_ValidFrom" ON "Iteration_REPLACE"."Definition_Example" ("ValidFrom");
CREATE INDEX "Idx_Definition_Example_ValidTo" ON "Iteration_REPLACE"."Definition_Example" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Definition_Example_Audit" (LIKE "Iteration_REPLACE"."Definition_Example");
ALTER TABLE "Iteration_REPLACE"."Definition_Example_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Definition_ExampleAudit_ValidFrom" ON "Iteration_REPLACE"."Definition_Example_Audit" ("ValidFrom");
CREATE INDEX "Idx_Definition_ExampleAudit_ValidTo" ON "Iteration_REPLACE"."Definition_Example_Audit" ("ValidTo");

CREATE TRIGGER Definition_Example_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Definition_Example"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Definition_Example_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Definition_Example"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER definition_example_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Definition_Example"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Definition', 'EngineeringModel_REPLACE');
-- Class Citation derives from Thing
ALTER TABLE "Iteration_REPLACE"."Citation" ADD CONSTRAINT "CitationDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Citation.Source is an association to ReferenceSource: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."Citation" ADD COLUMN "Source" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Citation" ADD CONSTRAINT "Citation_FK_Source" FOREIGN KEY ("Source") REFERENCES "SiteDirectory"."ReferenceSource" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class HyperLink derives from Thing
ALTER TABLE "Iteration_REPLACE"."HyperLink" ADD CONSTRAINT "HyperLinkDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class NestedElement derives from Thing
ALTER TABLE "Iteration_REPLACE"."NestedElement" ADD CONSTRAINT "NestedElementDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- NestedElement.RootElement is an association to ElementDefinition: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."NestedElement" ADD COLUMN "RootElement" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."NestedElement" ADD CONSTRAINT "NestedElement_FK_RootElement" FOREIGN KEY ("RootElement") REFERENCES "Iteration_REPLACE"."ElementDefinition" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ElementUsage is an ordered collection property (many to many) of class NestedElement: [1..*]-[0..*] (ordered)
CREATE TABLE "Iteration_REPLACE"."NestedElement_ElementUsage" (
  "NestedElement" uuid NOT NULL,
  "ElementUsage" uuid NOT NULL,
  "Sequence" bigint NOT NULL,
  CONSTRAINT "NestedElement_ElementUsage_PK" PRIMARY KEY("NestedElement", "ElementUsage"),
  CONSTRAINT "NestedElement_ElementUsage_FK_Source" FOREIGN KEY ("NestedElement") REFERENCES "Iteration_REPLACE"."NestedElement" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "NestedElement_ElementUsage_FK_Target" FOREIGN KEY ("ElementUsage") REFERENCES "Iteration_REPLACE"."ElementUsage" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."NestedElement_ElementUsage"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_NestedElement_ElementUsage_ValidFrom" ON "Iteration_REPLACE"."NestedElement_ElementUsage" ("ValidFrom");
CREATE INDEX "Idx_NestedElement_ElementUsage_ValidTo" ON "Iteration_REPLACE"."NestedElement_ElementUsage" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."NestedElement_ElementUsage_Audit" (LIKE "Iteration_REPLACE"."NestedElement_ElementUsage");
ALTER TABLE "Iteration_REPLACE"."NestedElement_ElementUsage_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_NestedElement_ElementUsageAudit_ValidFrom" ON "Iteration_REPLACE"."NestedElement_ElementUsage_Audit" ("ValidFrom");
CREATE INDEX "Idx_NestedElement_ElementUsageAudit_ValidTo" ON "Iteration_REPLACE"."NestedElement_ElementUsage_Audit" ("ValidTo");

CREATE TRIGGER NestedElement_ElementUsage_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."NestedElement_ElementUsage"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER NestedElement_ElementUsage_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."NestedElement_ElementUsage"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER nestedelement_elementusage_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."NestedElement_ElementUsage"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('NestedElement', 'EngineeringModel_REPLACE');
-- NestedParameter is contained (composite) by NestedElement: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."NestedParameter" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."NestedParameter" ADD CONSTRAINT "NestedParameter_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."NestedElement" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_NestedParameter_Container" ON "Iteration_REPLACE"."NestedParameter" ("Container");
CREATE TRIGGER nestedparameter_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."NestedParameter"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class NestedParameter derives from Thing
ALTER TABLE "Iteration_REPLACE"."NestedParameter" ADD CONSTRAINT "NestedParameterDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- NestedParameter.AssociatedParameter is an association to ParameterBase: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."NestedParameter" ADD COLUMN "AssociatedParameter" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."NestedParameter" ADD CONSTRAINT "NestedParameter_FK_AssociatedParameter" FOREIGN KEY ("AssociatedParameter") REFERENCES "Iteration_REPLACE"."ParameterBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- NestedParameter.ActualState is an optional association to ActualFiniteState: [0..1]-[1..1]
ALTER TABLE "Iteration_REPLACE"."NestedParameter" ADD COLUMN "ActualState" uuid;
ALTER TABLE "Iteration_REPLACE"."NestedParameter" ADD CONSTRAINT "NestedParameter_FK_ActualState" FOREIGN KEY ("ActualState") REFERENCES "Iteration_REPLACE"."ActualFiniteState" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- NestedParameter.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."NestedParameter" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."NestedParameter" ADD CONSTRAINT "NestedParameter_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Publication derives from Thing
ALTER TABLE "Iteration_REPLACE"."Publication" ADD CONSTRAINT "PublicationDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Domain is a collection property (many to many) of class Publication: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."Publication_Domain" (
  "Publication" uuid NOT NULL,
  "Domain" uuid NOT NULL,
  CONSTRAINT "Publication_Domain_PK" PRIMARY KEY("Publication", "Domain"),
  CONSTRAINT "Publication_Domain_FK_Source" FOREIGN KEY ("Publication") REFERENCES "Iteration_REPLACE"."Publication" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Publication_Domain_FK_Target" FOREIGN KEY ("Domain") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."Publication_Domain"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Publication_Domain_ValidFrom" ON "Iteration_REPLACE"."Publication_Domain" ("ValidFrom");
CREATE INDEX "Idx_Publication_Domain_ValidTo" ON "Iteration_REPLACE"."Publication_Domain" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Publication_Domain_Audit" (LIKE "Iteration_REPLACE"."Publication_Domain");
ALTER TABLE "Iteration_REPLACE"."Publication_Domain_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Publication_DomainAudit_ValidFrom" ON "Iteration_REPLACE"."Publication_Domain_Audit" ("ValidFrom");
CREATE INDEX "Idx_Publication_DomainAudit_ValidTo" ON "Iteration_REPLACE"."Publication_Domain_Audit" ("ValidTo");

CREATE TRIGGER Publication_Domain_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Publication_Domain"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Publication_Domain_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Publication_Domain"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER publication_domain_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Publication_Domain"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Publication', 'EngineeringModel_REPLACE');
-- PublishedParameter is a collection property (many to many) of class Publication: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."Publication_PublishedParameter" (
  "Publication" uuid NOT NULL,
  "PublishedParameter" uuid NOT NULL,
  CONSTRAINT "Publication_PublishedParameter_PK" PRIMARY KEY("Publication", "PublishedParameter"),
  CONSTRAINT "Publication_PublishedParameter_FK_Source" FOREIGN KEY ("Publication") REFERENCES "Iteration_REPLACE"."Publication" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Publication_PublishedParameter_FK_Target" FOREIGN KEY ("PublishedParameter") REFERENCES "Iteration_REPLACE"."ParameterOrOverrideBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."Publication_PublishedParameter"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Publication_PublishedParameter_ValidFrom" ON "Iteration_REPLACE"."Publication_PublishedParameter" ("ValidFrom");
CREATE INDEX "Idx_Publication_PublishedParameter_ValidTo" ON "Iteration_REPLACE"."Publication_PublishedParameter" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Publication_PublishedParameter_Audit" (LIKE "Iteration_REPLACE"."Publication_PublishedParameter");
ALTER TABLE "Iteration_REPLACE"."Publication_PublishedParameter_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Publication_PublishedParameterAudit_ValidFrom" ON "Iteration_REPLACE"."Publication_PublishedParameter_Audit" ("ValidFrom");
CREATE INDEX "Idx_Publication_PublishedParameterAudit_ValidTo" ON "Iteration_REPLACE"."Publication_PublishedParameter_Audit" ("ValidTo");

CREATE TRIGGER Publication_PublishedParameter_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Publication_PublishedParameter"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Publication_PublishedParameter_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Publication_PublishedParameter"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER publication_publishedparameter_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Publication_PublishedParameter"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Publication', 'EngineeringModel_REPLACE');
-- Class PossibleFiniteStateList derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList" ADD CONSTRAINT "PossibleFiniteStateListDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- PossibleFiniteState is contained (composite) by PossibleFiniteStateList: [1..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteState" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteState" ADD CONSTRAINT "PossibleFiniteState_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."PossibleFiniteStateList" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_PossibleFiniteState_Container" ON "Iteration_REPLACE"."PossibleFiniteState" ("Container");
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteState" ADD COLUMN "Sequence" bigint NOT NULL;
CREATE TRIGGER possiblefinitestate_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."PossibleFiniteState"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- PossibleFiniteStateList.DefaultState is an optional association to PossibleFiniteState: [0..1]-[1..1]
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList" ADD COLUMN "DefaultState" uuid;
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList" ADD CONSTRAINT "PossibleFiniteStateList_FK_DefaultState" FOREIGN KEY ("DefaultState") REFERENCES "Iteration_REPLACE"."PossibleFiniteState" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Category is a collection property (many to many) of class PossibleFiniteStateList: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."PossibleFiniteStateList_Category" (
  "PossibleFiniteStateList" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "PossibleFiniteStateList_Category_PK" PRIMARY KEY("PossibleFiniteStateList", "Category"),
  CONSTRAINT "PossibleFiniteStateList_Category_FK_Source" FOREIGN KEY ("PossibleFiniteStateList") REFERENCES "Iteration_REPLACE"."PossibleFiniteStateList" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "PossibleFiniteStateList_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_PossibleFiniteStateList_Category_ValidFrom" ON "Iteration_REPLACE"."PossibleFiniteStateList_Category" ("ValidFrom");
CREATE INDEX "Idx_PossibleFiniteStateList_Category_ValidTo" ON "Iteration_REPLACE"."PossibleFiniteStateList_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."PossibleFiniteStateList_Category_Audit" (LIKE "Iteration_REPLACE"."PossibleFiniteStateList_Category");
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_PossibleFiniteStateList_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."PossibleFiniteStateList_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_PossibleFiniteStateList_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."PossibleFiniteStateList_Category_Audit" ("ValidTo");

CREATE TRIGGER PossibleFiniteStateList_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."PossibleFiniteStateList_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER PossibleFiniteStateList_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."PossibleFiniteStateList_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER possiblefinitestatelist_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."PossibleFiniteStateList_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('PossibleFiniteStateList', 'EngineeringModel_REPLACE');
-- PossibleFiniteStateList.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList" ADD CONSTRAINT "PossibleFiniteStateList_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class PossibleFiniteState derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteState" ADD CONSTRAINT "PossibleFiniteStateDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ElementBase derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."ElementBase" ADD CONSTRAINT "ElementBaseDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Category is a collection property (many to many) of class ElementBase: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."ElementBase_Category" (
  "ElementBase" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "ElementBase_Category_PK" PRIMARY KEY("ElementBase", "Category"),
  CONSTRAINT "ElementBase_Category_FK_Source" FOREIGN KEY ("ElementBase") REFERENCES "Iteration_REPLACE"."ElementBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ElementBase_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."ElementBase_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ElementBase_Category_ValidFrom" ON "Iteration_REPLACE"."ElementBase_Category" ("ValidFrom");
CREATE INDEX "Idx_ElementBase_Category_ValidTo" ON "Iteration_REPLACE"."ElementBase_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ElementBase_Category_Audit" (LIKE "Iteration_REPLACE"."ElementBase_Category");
ALTER TABLE "Iteration_REPLACE"."ElementBase_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ElementBase_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."ElementBase_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_ElementBase_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."ElementBase_Category_Audit" ("ValidTo");

CREATE TRIGGER ElementBase_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ElementBase_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ElementBase_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ElementBase_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER elementbase_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ElementBase_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ElementBase', 'EngineeringModel_REPLACE');
-- ElementBase.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ElementBase" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ElementBase" ADD CONSTRAINT "ElementBase_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ElementDefinition derives from ElementBase
ALTER TABLE "Iteration_REPLACE"."ElementDefinition" ADD CONSTRAINT "ElementDefinitionDerivesFromElementBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."ElementBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ElementUsage is contained (composite) by ElementDefinition: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ElementUsage" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ElementUsage" ADD CONSTRAINT "ElementUsage_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."ElementDefinition" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ElementUsage_Container" ON "Iteration_REPLACE"."ElementUsage" ("Container");
CREATE TRIGGER elementusage_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ElementUsage"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Parameter is contained (composite) by ElementDefinition: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Parameter" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Parameter" ADD CONSTRAINT "Parameter_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."ElementDefinition" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Parameter_Container" ON "Iteration_REPLACE"."Parameter" ("Container");
CREATE TRIGGER parameter_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Parameter"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- ParameterGroup is contained (composite) by ElementDefinition: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ParameterGroup" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterGroup" ADD CONSTRAINT "ParameterGroup_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."ElementDefinition" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ParameterGroup_Container" ON "Iteration_REPLACE"."ParameterGroup" ("Container");
CREATE TRIGGER parametergroup_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ParameterGroup"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- ReferencedElement is a collection property (many to many) of class ElementDefinition: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."ElementDefinition_ReferencedElement" (
  "ElementDefinition" uuid NOT NULL,
  "ReferencedElement" uuid NOT NULL,
  CONSTRAINT "ElementDefinition_ReferencedElement_PK" PRIMARY KEY("ElementDefinition", "ReferencedElement"),
  CONSTRAINT "ElementDefinition_ReferencedElement_FK_Source" FOREIGN KEY ("ElementDefinition") REFERENCES "Iteration_REPLACE"."ElementDefinition" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ElementDefinition_ReferencedElement_FK_Target" FOREIGN KEY ("ReferencedElement") REFERENCES "Iteration_REPLACE"."NestedElement" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."ElementDefinition_ReferencedElement"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ElementDefinition_ReferencedElement_ValidFrom" ON "Iteration_REPLACE"."ElementDefinition_ReferencedElement" ("ValidFrom");
CREATE INDEX "Idx_ElementDefinition_ReferencedElement_ValidTo" ON "Iteration_REPLACE"."ElementDefinition_ReferencedElement" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ElementDefinition_ReferencedElement_Audit" (LIKE "Iteration_REPLACE"."ElementDefinition_ReferencedElement");
ALTER TABLE "Iteration_REPLACE"."ElementDefinition_ReferencedElement_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ElementDefinition_ReferencedElementAudit_ValidFrom" ON "Iteration_REPLACE"."ElementDefinition_ReferencedElement_Audit" ("ValidFrom");
CREATE INDEX "Idx_ElementDefinition_ReferencedElementAudit_ValidTo" ON "Iteration_REPLACE"."ElementDefinition_ReferencedElement_Audit" ("ValidTo");

CREATE TRIGGER ElementDefinition_ReferencedElement_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ElementDefinition_ReferencedElement"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ElementDefinition_ReferencedElement_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ElementDefinition_ReferencedElement"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER elementdefinition_referencedelement_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ElementDefinition_ReferencedElement"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ElementDefinition', 'EngineeringModel_REPLACE');
-- Class ElementUsage derives from ElementBase
ALTER TABLE "Iteration_REPLACE"."ElementUsage" ADD CONSTRAINT "ElementUsageDerivesFromElementBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."ElementBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ElementUsage.ElementDefinition is an association to ElementDefinition: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ElementUsage" ADD COLUMN "ElementDefinition" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ElementUsage" ADD CONSTRAINT "ElementUsage_FK_ElementDefinition" FOREIGN KEY ("ElementDefinition") REFERENCES "Iteration_REPLACE"."ElementDefinition" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterOverride is contained (composite) by ElementUsage: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ParameterOverride" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterOverride" ADD CONSTRAINT "ParameterOverride_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."ElementUsage" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ParameterOverride_Container" ON "Iteration_REPLACE"."ParameterOverride" ("Container");
CREATE TRIGGER parameteroverride_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ParameterOverride"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- ExcludeOption is a collection property (many to many) of class ElementUsage: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."ElementUsage_ExcludeOption" (
  "ElementUsage" uuid NOT NULL,
  "ExcludeOption" uuid NOT NULL,
  CONSTRAINT "ElementUsage_ExcludeOption_PK" PRIMARY KEY("ElementUsage", "ExcludeOption"),
  CONSTRAINT "ElementUsage_ExcludeOption_FK_Source" FOREIGN KEY ("ElementUsage") REFERENCES "Iteration_REPLACE"."ElementUsage" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ElementUsage_ExcludeOption_FK_Target" FOREIGN KEY ("ExcludeOption") REFERENCES "Iteration_REPLACE"."Option" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."ElementUsage_ExcludeOption"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ElementUsage_ExcludeOption_ValidFrom" ON "Iteration_REPLACE"."ElementUsage_ExcludeOption" ("ValidFrom");
CREATE INDEX "Idx_ElementUsage_ExcludeOption_ValidTo" ON "Iteration_REPLACE"."ElementUsage_ExcludeOption" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ElementUsage_ExcludeOption_Audit" (LIKE "Iteration_REPLACE"."ElementUsage_ExcludeOption");
ALTER TABLE "Iteration_REPLACE"."ElementUsage_ExcludeOption_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ElementUsage_ExcludeOptionAudit_ValidFrom" ON "Iteration_REPLACE"."ElementUsage_ExcludeOption_Audit" ("ValidFrom");
CREATE INDEX "Idx_ElementUsage_ExcludeOptionAudit_ValidTo" ON "Iteration_REPLACE"."ElementUsage_ExcludeOption_Audit" ("ValidTo");

CREATE TRIGGER ElementUsage_ExcludeOption_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ElementUsage_ExcludeOption"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ElementUsage_ExcludeOption_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ElementUsage_ExcludeOption"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER elementusage_excludeoption_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ElementUsage_ExcludeOption"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ElementUsage', 'EngineeringModel_REPLACE');
-- Class ParameterBase derives from Thing
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD CONSTRAINT "ParameterBaseDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterBase.ParameterType is an association to ParameterType: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD COLUMN "ParameterType" uuid;
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD CONSTRAINT "ParameterBase_FK_ParameterType" FOREIGN KEY ("ParameterType") REFERENCES "SiteDirectory"."ParameterType" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterBase.Scale is an optional association to MeasurementScale: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD COLUMN "Scale" uuid;
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD CONSTRAINT "ParameterBase_FK_Scale" FOREIGN KEY ("Scale") REFERENCES "SiteDirectory"."MeasurementScale" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- ParameterBase.StateDependence is an optional association to ActualFiniteStateList: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD COLUMN "StateDependence" uuid;
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD CONSTRAINT "ParameterBase_FK_StateDependence" FOREIGN KEY ("StateDependence") REFERENCES "Iteration_REPLACE"."ActualFiniteStateList" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- ParameterBase.Group is an optional association to ParameterGroup: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD COLUMN "Group" uuid;
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD CONSTRAINT "ParameterBase_FK_Group" FOREIGN KEY ("Group") REFERENCES "Iteration_REPLACE"."ParameterGroup" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- ParameterBase.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterBase" ADD CONSTRAINT "ParameterBase_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ParameterOrOverrideBase derives from ParameterBase
ALTER TABLE "Iteration_REPLACE"."ParameterOrOverrideBase" ADD CONSTRAINT "ParameterOrOverrideBaseDerivesFromParameterBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."ParameterBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterSubscription is contained (composite) by ParameterOrOverrideBase: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ParameterSubscription" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterSubscription" ADD CONSTRAINT "ParameterSubscription_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."ParameterOrOverrideBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ParameterSubscription_Container" ON "Iteration_REPLACE"."ParameterSubscription" ("Container");
CREATE TRIGGER parametersubscription_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ParameterSubscription"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class ParameterOverride derives from ParameterOrOverrideBase
ALTER TABLE "Iteration_REPLACE"."ParameterOverride" ADD CONSTRAINT "ParameterOverrideDerivesFromParameterOrOverrideBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."ParameterOrOverrideBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterOverride.Parameter is an association to Parameter: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterOverride" ADD COLUMN "Parameter" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterOverride" ADD CONSTRAINT "ParameterOverride_FK_Parameter" FOREIGN KEY ("Parameter") REFERENCES "Iteration_REPLACE"."Parameter" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterOverrideValueSet is contained (composite) by ParameterOverride: [1..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ParameterOverrideValueSet" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterOverrideValueSet" ADD CONSTRAINT "ParameterOverrideValueSet_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."ParameterOverride" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ParameterOverrideValueSet_Container" ON "Iteration_REPLACE"."ParameterOverrideValueSet" ("Container");
CREATE TRIGGER parameteroverridevalueset_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ParameterOverrideValueSet"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class ParameterSubscription derives from ParameterBase
ALTER TABLE "Iteration_REPLACE"."ParameterSubscription" ADD CONSTRAINT "ParameterSubscriptionDerivesFromParameterBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."ParameterBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterSubscriptionValueSet is contained (composite) by ParameterSubscription: [1..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet" ADD CONSTRAINT "ParameterSubscriptionValueSet_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."ParameterSubscription" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ParameterSubscriptionValueSet_Container" ON "Iteration_REPLACE"."ParameterSubscriptionValueSet" ("Container");
CREATE TRIGGER parametersubscriptionvalueset_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ParameterSubscriptionValueSet"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class ParameterSubscriptionValueSet derives from Thing
ALTER TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet" ADD CONSTRAINT "ParameterSubscriptionValueSetDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterSubscriptionValueSet.SubscribedValueSet is an association to ParameterValueSetBase: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet" ADD COLUMN "SubscribedValueSet" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet" ADD CONSTRAINT "ParameterSubscriptionValueSet_FK_SubscribedValueSet" FOREIGN KEY ("SubscribedValueSet") REFERENCES "Iteration_REPLACE"."ParameterValueSetBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ParameterValueSetBase derives from Thing
ALTER TABLE "Iteration_REPLACE"."ParameterValueSetBase" ADD CONSTRAINT "ParameterValueSetBaseDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterValueSetBase.ActualState is an optional association to ActualFiniteState: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterValueSetBase" ADD COLUMN "ActualState" uuid;
ALTER TABLE "Iteration_REPLACE"."ParameterValueSetBase" ADD CONSTRAINT "ParameterValueSetBase_FK_ActualState" FOREIGN KEY ("ActualState") REFERENCES "Iteration_REPLACE"."ActualFiniteState" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- ParameterValueSetBase.ActualOption is an optional association to Option: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterValueSetBase" ADD COLUMN "ActualOption" uuid;
ALTER TABLE "Iteration_REPLACE"."ParameterValueSetBase" ADD CONSTRAINT "ParameterValueSetBase_FK_ActualOption" FOREIGN KEY ("ActualOption") REFERENCES "Iteration_REPLACE"."Option" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Class ParameterOverrideValueSet derives from ParameterValueSetBase
ALTER TABLE "Iteration_REPLACE"."ParameterOverrideValueSet" ADD CONSTRAINT "ParameterOverrideValueSetDerivesFromParameterValueSetBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."ParameterValueSetBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterOverrideValueSet.ParameterValueSet is an association to ParameterValueSet: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterOverrideValueSet" ADD COLUMN "ParameterValueSet" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterOverrideValueSet" ADD CONSTRAINT "ParameterOverrideValueSet_FK_ParameterValueSet" FOREIGN KEY ("ParameterValueSet") REFERENCES "Iteration_REPLACE"."ParameterValueSet" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Parameter derives from ParameterOrOverrideBase
ALTER TABLE "Iteration_REPLACE"."Parameter" ADD CONSTRAINT "ParameterDerivesFromParameterOrOverrideBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."ParameterOrOverrideBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Parameter.RequestedBy is an optional association to DomainOfExpertise: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."Parameter" ADD COLUMN "RequestedBy" uuid;
ALTER TABLE "Iteration_REPLACE"."Parameter" ADD CONSTRAINT "Parameter_FK_RequestedBy" FOREIGN KEY ("RequestedBy") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- ParameterValueSet is contained (composite) by Parameter: [1..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ParameterValueSet" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterValueSet" ADD CONSTRAINT "ParameterValueSet_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."Parameter" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ParameterValueSet_Container" ON "Iteration_REPLACE"."ParameterValueSet" ("Container");
CREATE TRIGGER parametervalueset_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ParameterValueSet"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class ParameterValueSet derives from ParameterValueSetBase
ALTER TABLE "Iteration_REPLACE"."ParameterValueSet" ADD CONSTRAINT "ParameterValueSetDerivesFromParameterValueSetBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."ParameterValueSetBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ParameterGroup derives from Thing
ALTER TABLE "Iteration_REPLACE"."ParameterGroup" ADD CONSTRAINT "ParameterGroupDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterGroup.ContainingGroup is an optional association to ParameterGroup: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ParameterGroup" ADD COLUMN "ContainingGroup" uuid;
ALTER TABLE "Iteration_REPLACE"."ParameterGroup" ADD CONSTRAINT "ParameterGroup_FK_ContainingGroup" FOREIGN KEY ("ContainingGroup") REFERENCES "Iteration_REPLACE"."ParameterGroup" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Class Relationship derives from Thing
ALTER TABLE "Iteration_REPLACE"."Relationship" ADD CONSTRAINT "RelationshipDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- RelationshipParameterValue is contained (composite) by Relationship: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."RelationshipParameterValue" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."RelationshipParameterValue" ADD CONSTRAINT "RelationshipParameterValue_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."Relationship" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_RelationshipParameterValue_Container" ON "Iteration_REPLACE"."RelationshipParameterValue" ("Container");
CREATE TRIGGER relationshipparametervalue_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."RelationshipParameterValue"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Category is a collection property (many to many) of class Relationship: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."Relationship_Category" (
  "Relationship" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "Relationship_Category_PK" PRIMARY KEY("Relationship", "Category"),
  CONSTRAINT "Relationship_Category_FK_Source" FOREIGN KEY ("Relationship") REFERENCES "Iteration_REPLACE"."Relationship" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Relationship_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."Relationship_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Relationship_Category_ValidFrom" ON "Iteration_REPLACE"."Relationship_Category" ("ValidFrom");
CREATE INDEX "Idx_Relationship_Category_ValidTo" ON "Iteration_REPLACE"."Relationship_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Relationship_Category_Audit" (LIKE "Iteration_REPLACE"."Relationship_Category");
ALTER TABLE "Iteration_REPLACE"."Relationship_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Relationship_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."Relationship_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_Relationship_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."Relationship_Category_Audit" ("ValidTo");

CREATE TRIGGER Relationship_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Relationship_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Relationship_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Relationship_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER relationship_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Relationship_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Relationship', 'EngineeringModel_REPLACE');
-- Relationship.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."Relationship" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Relationship" ADD CONSTRAINT "Relationship_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class MultiRelationship derives from Relationship
ALTER TABLE "Iteration_REPLACE"."MultiRelationship" ADD CONSTRAINT "MultiRelationshipDerivesFromRelationship" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Relationship" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- RelatedThing is a collection property (many to many) of class MultiRelationship: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."MultiRelationship_RelatedThing" (
  "MultiRelationship" uuid NOT NULL,
  "RelatedThing" uuid NOT NULL,
  CONSTRAINT "MultiRelationship_RelatedThing_PK" PRIMARY KEY("MultiRelationship", "RelatedThing"),
  CONSTRAINT "MultiRelationship_RelatedThing_FK_Source" FOREIGN KEY ("MultiRelationship") REFERENCES "Iteration_REPLACE"."MultiRelationship" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "MultiRelationship_RelatedThing_FK_Target" FOREIGN KEY ("RelatedThing") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."MultiRelationship_RelatedThing"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_MultiRelationship_RelatedThing_ValidFrom" ON "Iteration_REPLACE"."MultiRelationship_RelatedThing" ("ValidFrom");
CREATE INDEX "Idx_MultiRelationship_RelatedThing_ValidTo" ON "Iteration_REPLACE"."MultiRelationship_RelatedThing" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."MultiRelationship_RelatedThing_Audit" (LIKE "Iteration_REPLACE"."MultiRelationship_RelatedThing");
ALTER TABLE "Iteration_REPLACE"."MultiRelationship_RelatedThing_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_MultiRelationship_RelatedThingAudit_ValidFrom" ON "Iteration_REPLACE"."MultiRelationship_RelatedThing_Audit" ("ValidFrom");
CREATE INDEX "Idx_MultiRelationship_RelatedThingAudit_ValidTo" ON "Iteration_REPLACE"."MultiRelationship_RelatedThing_Audit" ("ValidTo");

CREATE TRIGGER MultiRelationship_RelatedThing_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."MultiRelationship_RelatedThing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER MultiRelationship_RelatedThing_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."MultiRelationship_RelatedThing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER multirelationship_relatedthing_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."MultiRelationship_RelatedThing"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('MultiRelationship', 'EngineeringModel_REPLACE');
-- Class ParameterValue derives from Thing
ALTER TABLE "Iteration_REPLACE"."ParameterValue" ADD CONSTRAINT "ParameterValueDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterValue.ParameterType is an association to ParameterType: [1..1]
ALTER TABLE "Iteration_REPLACE"."ParameterValue" ADD COLUMN "ParameterType" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParameterValue" ADD CONSTRAINT "ParameterValue_FK_ParameterType" FOREIGN KEY ("ParameterType") REFERENCES "SiteDirectory"."ParameterType" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParameterValue.Scale is an optional association to MeasurementScale: [0..1]
ALTER TABLE "Iteration_REPLACE"."ParameterValue" ADD COLUMN "Scale" uuid;
ALTER TABLE "Iteration_REPLACE"."ParameterValue" ADD CONSTRAINT "ParameterValue_FK_Scale" FOREIGN KEY ("Scale") REFERENCES "SiteDirectory"."MeasurementScale" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Class RelationshipParameterValue derives from ParameterValue
ALTER TABLE "Iteration_REPLACE"."RelationshipParameterValue" ADD CONSTRAINT "RelationshipParameterValueDerivesFromParameterValue" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."ParameterValue" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class BinaryRelationship derives from Relationship
ALTER TABLE "Iteration_REPLACE"."BinaryRelationship" ADD CONSTRAINT "BinaryRelationshipDerivesFromRelationship" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Relationship" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- BinaryRelationship.Source is an association to Thing: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."BinaryRelationship" ADD COLUMN "Source" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."BinaryRelationship" ADD CONSTRAINT "BinaryRelationship_FK_Source" FOREIGN KEY ("Source") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- BinaryRelationship.Target is an association to Thing: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."BinaryRelationship" ADD COLUMN "Target" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."BinaryRelationship" ADD CONSTRAINT "BinaryRelationship_FK_Target" FOREIGN KEY ("Target") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ExternalIdentifierMap derives from Thing
ALTER TABLE "Iteration_REPLACE"."ExternalIdentifierMap" ADD CONSTRAINT "ExternalIdentifierMapDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- IdCorrespondence is contained (composite) by ExternalIdentifierMap: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."IdCorrespondence" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."IdCorrespondence" ADD CONSTRAINT "IdCorrespondence_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."ExternalIdentifierMap" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_IdCorrespondence_Container" ON "Iteration_REPLACE"."IdCorrespondence" ("Container");
CREATE TRIGGER idcorrespondence_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."IdCorrespondence"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- ExternalIdentifierMap.ExternalFormat is an optional association to ReferenceSource: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ExternalIdentifierMap" ADD COLUMN "ExternalFormat" uuid;
ALTER TABLE "Iteration_REPLACE"."ExternalIdentifierMap" ADD CONSTRAINT "ExternalIdentifierMap_FK_ExternalFormat" FOREIGN KEY ("ExternalFormat") REFERENCES "SiteDirectory"."ReferenceSource" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- ExternalIdentifierMap.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ExternalIdentifierMap" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ExternalIdentifierMap" ADD CONSTRAINT "ExternalIdentifierMap_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class IdCorrespondence derives from Thing
ALTER TABLE "Iteration_REPLACE"."IdCorrespondence" ADD CONSTRAINT "IdCorrespondenceDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class RequirementsContainer derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."RequirementsContainer" ADD CONSTRAINT "RequirementsContainerDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- RequirementsGroup is contained (composite) by RequirementsContainer: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."RequirementsGroup" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."RequirementsGroup" ADD CONSTRAINT "RequirementsGroup_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."RequirementsContainer" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_RequirementsGroup_Container" ON "Iteration_REPLACE"."RequirementsGroup" ("Container");
CREATE TRIGGER requirementsgroup_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."RequirementsGroup"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- RequirementsContainerParameterValue is contained (composite) by RequirementsContainer: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."RequirementsContainerParameterValue" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."RequirementsContainerParameterValue" ADD CONSTRAINT "RequirementsContainerParameterValue_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."RequirementsContainer" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_RequirementsContainerParameterValue_Container" ON "Iteration_REPLACE"."RequirementsContainerParameterValue" ("Container");
CREATE TRIGGER requirementscontainerparametervalue_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."RequirementsContainerParameterValue"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- RequirementsContainer.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."RequirementsContainer" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."RequirementsContainer" ADD CONSTRAINT "RequirementsContainer_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Category is a collection property (many to many) of class RequirementsContainer: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."RequirementsContainer_Category" (
  "RequirementsContainer" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "RequirementsContainer_Category_PK" PRIMARY KEY("RequirementsContainer", "Category"),
  CONSTRAINT "RequirementsContainer_Category_FK_Source" FOREIGN KEY ("RequirementsContainer") REFERENCES "Iteration_REPLACE"."RequirementsContainer" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "RequirementsContainer_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."RequirementsContainer_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RequirementsContainer_Category_ValidFrom" ON "Iteration_REPLACE"."RequirementsContainer_Category" ("ValidFrom");
CREATE INDEX "Idx_RequirementsContainer_Category_ValidTo" ON "Iteration_REPLACE"."RequirementsContainer_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RequirementsContainer_Category_Audit" (LIKE "Iteration_REPLACE"."RequirementsContainer_Category");
ALTER TABLE "Iteration_REPLACE"."RequirementsContainer_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RequirementsContainer_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."RequirementsContainer_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_RequirementsContainer_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."RequirementsContainer_Category_Audit" ("ValidTo");

CREATE TRIGGER RequirementsContainer_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RequirementsContainer_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RequirementsContainer_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RequirementsContainer_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER requirementscontainer_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."RequirementsContainer_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('RequirementsContainer', 'EngineeringModel_REPLACE');
-- Class RequirementsSpecification derives from RequirementsContainer
ALTER TABLE "Iteration_REPLACE"."RequirementsSpecification" ADD CONSTRAINT "RequirementsSpecificationDerivesFromRequirementsContainer" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."RequirementsContainer" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Requirement is contained (composite) by RequirementsSpecification: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Requirement" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Requirement" ADD CONSTRAINT "Requirement_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."RequirementsSpecification" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Requirement_Container" ON "Iteration_REPLACE"."Requirement" ("Container");
CREATE TRIGGER requirement_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Requirement"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class RequirementsGroup derives from RequirementsContainer
ALTER TABLE "Iteration_REPLACE"."RequirementsGroup" ADD CONSTRAINT "RequirementsGroupDerivesFromRequirementsContainer" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."RequirementsContainer" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class RequirementsContainerParameterValue derives from ParameterValue
ALTER TABLE "Iteration_REPLACE"."RequirementsContainerParameterValue" ADD CONSTRAINT "RequirementsContainerParameterValueDerivesFromParameterValue" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."ParameterValue" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class SimpleParameterizableThing derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."SimpleParameterizableThing" ADD CONSTRAINT "SimpleParameterizableThingDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- SimpleParameterValue is contained (composite) by SimpleParameterizableThing: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."SimpleParameterValue" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."SimpleParameterValue" ADD CONSTRAINT "SimpleParameterValue_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."SimpleParameterizableThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_SimpleParameterValue_Container" ON "Iteration_REPLACE"."SimpleParameterValue" ("Container");
CREATE TRIGGER simpleparametervalue_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."SimpleParameterValue"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- SimpleParameterizableThing.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."SimpleParameterizableThing" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."SimpleParameterizableThing" ADD CONSTRAINT "SimpleParameterizableThing_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Requirement derives from SimpleParameterizableThing
ALTER TABLE "Iteration_REPLACE"."Requirement" ADD CONSTRAINT "RequirementDerivesFromSimpleParameterizableThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."SimpleParameterizableThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ParametricConstraint is contained (composite) by Requirement: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ParametricConstraint" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ParametricConstraint" ADD CONSTRAINT "ParametricConstraint_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."Requirement" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ParametricConstraint_Container" ON "Iteration_REPLACE"."ParametricConstraint" ("Container");
ALTER TABLE "Iteration_REPLACE"."ParametricConstraint" ADD COLUMN "Sequence" bigint NOT NULL;
CREATE TRIGGER parametricconstraint_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ParametricConstraint"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Requirement.Group is an optional association to RequirementsGroup: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."Requirement" ADD COLUMN "Group" uuid;
ALTER TABLE "Iteration_REPLACE"."Requirement" ADD CONSTRAINT "Requirement_FK_Group" FOREIGN KEY ("Group") REFERENCES "Iteration_REPLACE"."RequirementsGroup" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Category is a collection property (many to many) of class Requirement: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."Requirement_Category" (
  "Requirement" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "Requirement_Category_PK" PRIMARY KEY("Requirement", "Category"),
  CONSTRAINT "Requirement_Category_FK_Source" FOREIGN KEY ("Requirement") REFERENCES "Iteration_REPLACE"."Requirement" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Requirement_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."Requirement_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Requirement_Category_ValidFrom" ON "Iteration_REPLACE"."Requirement_Category" ("ValidFrom");
CREATE INDEX "Idx_Requirement_Category_ValidTo" ON "Iteration_REPLACE"."Requirement_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Requirement_Category_Audit" (LIKE "Iteration_REPLACE"."Requirement_Category");
ALTER TABLE "Iteration_REPLACE"."Requirement_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Requirement_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."Requirement_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_Requirement_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."Requirement_Category_Audit" ("ValidTo");

CREATE TRIGGER Requirement_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Requirement_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Requirement_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Requirement_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER requirement_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Requirement_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Requirement', 'EngineeringModel_REPLACE');
-- Class SimpleParameterValue derives from Thing
ALTER TABLE "Iteration_REPLACE"."SimpleParameterValue" ADD CONSTRAINT "SimpleParameterValueDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- SimpleParameterValue.ParameterType is an association to ParameterType: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."SimpleParameterValue" ADD COLUMN "ParameterType" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."SimpleParameterValue" ADD CONSTRAINT "SimpleParameterValue_FK_ParameterType" FOREIGN KEY ("ParameterType") REFERENCES "SiteDirectory"."ParameterType" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- SimpleParameterValue.Scale is an optional association to MeasurementScale: [0..1]
ALTER TABLE "Iteration_REPLACE"."SimpleParameterValue" ADD COLUMN "Scale" uuid;
ALTER TABLE "Iteration_REPLACE"."SimpleParameterValue" ADD CONSTRAINT "SimpleParameterValue_FK_Scale" FOREIGN KEY ("Scale") REFERENCES "SiteDirectory"."MeasurementScale" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Class ParametricConstraint derives from Thing
ALTER TABLE "Iteration_REPLACE"."ParametricConstraint" ADD CONSTRAINT "ParametricConstraintDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- BooleanExpression is contained (composite) by ParametricConstraint: [1..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."BooleanExpression" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."BooleanExpression" ADD CONSTRAINT "BooleanExpression_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."ParametricConstraint" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_BooleanExpression_Container" ON "Iteration_REPLACE"."BooleanExpression" ("Container");
CREATE TRIGGER booleanexpression_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."BooleanExpression"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- ParametricConstraint.TopExpression is an optional association to BooleanExpression: [0..1]-[0..1]
ALTER TABLE "Iteration_REPLACE"."ParametricConstraint" ADD COLUMN "TopExpression" uuid;
ALTER TABLE "Iteration_REPLACE"."ParametricConstraint" ADD CONSTRAINT "ParametricConstraint_FK_TopExpression" FOREIGN KEY ("TopExpression") REFERENCES "Iteration_REPLACE"."BooleanExpression" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Class BooleanExpression derives from Thing
ALTER TABLE "Iteration_REPLACE"."BooleanExpression" ADD CONSTRAINT "BooleanExpressionDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class OrExpression derives from BooleanExpression
ALTER TABLE "Iteration_REPLACE"."OrExpression" ADD CONSTRAINT "OrExpressionDerivesFromBooleanExpression" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."BooleanExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Term is a collection property (many to many) of class OrExpression: [2..*]-[0..1]
CREATE TABLE "Iteration_REPLACE"."OrExpression_Term" (
  "OrExpression" uuid NOT NULL,
  "Term" uuid NOT NULL,
  CONSTRAINT "OrExpression_Term_PK" PRIMARY KEY("OrExpression", "Term"),
  CONSTRAINT "OrExpression_Term_FK_Source" FOREIGN KEY ("OrExpression") REFERENCES "Iteration_REPLACE"."OrExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "OrExpression_Term_FK_Target" FOREIGN KEY ("Term") REFERENCES "Iteration_REPLACE"."BooleanExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."OrExpression_Term"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_OrExpression_Term_ValidFrom" ON "Iteration_REPLACE"."OrExpression_Term" ("ValidFrom");
CREATE INDEX "Idx_OrExpression_Term_ValidTo" ON "Iteration_REPLACE"."OrExpression_Term" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."OrExpression_Term_Audit" (LIKE "Iteration_REPLACE"."OrExpression_Term");
ALTER TABLE "Iteration_REPLACE"."OrExpression_Term_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_OrExpression_TermAudit_ValidFrom" ON "Iteration_REPLACE"."OrExpression_Term_Audit" ("ValidFrom");
CREATE INDEX "Idx_OrExpression_TermAudit_ValidTo" ON "Iteration_REPLACE"."OrExpression_Term_Audit" ("ValidTo");

CREATE TRIGGER OrExpression_Term_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."OrExpression_Term"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER OrExpression_Term_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."OrExpression_Term"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER orexpression_term_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."OrExpression_Term"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('OrExpression', 'EngineeringModel_REPLACE');
-- Class NotExpression derives from BooleanExpression
ALTER TABLE "Iteration_REPLACE"."NotExpression" ADD CONSTRAINT "NotExpressionDerivesFromBooleanExpression" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."BooleanExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- NotExpression.Term is an association to BooleanExpression: [1..1]-[0..1]
ALTER TABLE "Iteration_REPLACE"."NotExpression" ADD COLUMN "Term" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."NotExpression" ADD CONSTRAINT "NotExpression_FK_Term" FOREIGN KEY ("Term") REFERENCES "Iteration_REPLACE"."BooleanExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class AndExpression derives from BooleanExpression
ALTER TABLE "Iteration_REPLACE"."AndExpression" ADD CONSTRAINT "AndExpressionDerivesFromBooleanExpression" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."BooleanExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Term is a collection property (many to many) of class AndExpression: [2..*]-[0..1]
CREATE TABLE "Iteration_REPLACE"."AndExpression_Term" (
  "AndExpression" uuid NOT NULL,
  "Term" uuid NOT NULL,
  CONSTRAINT "AndExpression_Term_PK" PRIMARY KEY("AndExpression", "Term"),
  CONSTRAINT "AndExpression_Term_FK_Source" FOREIGN KEY ("AndExpression") REFERENCES "Iteration_REPLACE"."AndExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "AndExpression_Term_FK_Target" FOREIGN KEY ("Term") REFERENCES "Iteration_REPLACE"."BooleanExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."AndExpression_Term"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_AndExpression_Term_ValidFrom" ON "Iteration_REPLACE"."AndExpression_Term" ("ValidFrom");
CREATE INDEX "Idx_AndExpression_Term_ValidTo" ON "Iteration_REPLACE"."AndExpression_Term" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."AndExpression_Term_Audit" (LIKE "Iteration_REPLACE"."AndExpression_Term");
ALTER TABLE "Iteration_REPLACE"."AndExpression_Term_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_AndExpression_TermAudit_ValidFrom" ON "Iteration_REPLACE"."AndExpression_Term_Audit" ("ValidFrom");
CREATE INDEX "Idx_AndExpression_TermAudit_ValidTo" ON "Iteration_REPLACE"."AndExpression_Term_Audit" ("ValidTo");

CREATE TRIGGER AndExpression_Term_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."AndExpression_Term"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER AndExpression_Term_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."AndExpression_Term"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER andexpression_term_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."AndExpression_Term"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('AndExpression', 'EngineeringModel_REPLACE');
-- Class ExclusiveOrExpression derives from BooleanExpression
ALTER TABLE "Iteration_REPLACE"."ExclusiveOrExpression" ADD CONSTRAINT "ExclusiveOrExpressionDerivesFromBooleanExpression" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."BooleanExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Term is a collection property (many to many) of class ExclusiveOrExpression: [2..2]-[0..1]
CREATE TABLE "Iteration_REPLACE"."ExclusiveOrExpression_Term" (
  "ExclusiveOrExpression" uuid NOT NULL,
  "Term" uuid NOT NULL,
  CONSTRAINT "ExclusiveOrExpression_Term_PK" PRIMARY KEY("ExclusiveOrExpression", "Term"),
  CONSTRAINT "ExclusiveOrExpression_Term_FK_Source" FOREIGN KEY ("ExclusiveOrExpression") REFERENCES "Iteration_REPLACE"."ExclusiveOrExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ExclusiveOrExpression_Term_FK_Target" FOREIGN KEY ("Term") REFERENCES "Iteration_REPLACE"."BooleanExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."ExclusiveOrExpression_Term"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ExclusiveOrExpression_Term_ValidFrom" ON "Iteration_REPLACE"."ExclusiveOrExpression_Term" ("ValidFrom");
CREATE INDEX "Idx_ExclusiveOrExpression_Term_ValidTo" ON "Iteration_REPLACE"."ExclusiveOrExpression_Term" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ExclusiveOrExpression_Term_Audit" (LIKE "Iteration_REPLACE"."ExclusiveOrExpression_Term");
ALTER TABLE "Iteration_REPLACE"."ExclusiveOrExpression_Term_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ExclusiveOrExpression_TermAudit_ValidFrom" ON "Iteration_REPLACE"."ExclusiveOrExpression_Term_Audit" ("ValidFrom");
CREATE INDEX "Idx_ExclusiveOrExpression_TermAudit_ValidTo" ON "Iteration_REPLACE"."ExclusiveOrExpression_Term_Audit" ("ValidTo");

CREATE TRIGGER ExclusiveOrExpression_Term_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ExclusiveOrExpression_Term"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ExclusiveOrExpression_Term_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ExclusiveOrExpression_Term"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER exclusiveorexpression_term_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ExclusiveOrExpression_Term"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ExclusiveOrExpression', 'EngineeringModel_REPLACE');
-- Class RelationalExpression derives from BooleanExpression
ALTER TABLE "Iteration_REPLACE"."RelationalExpression" ADD CONSTRAINT "RelationalExpressionDerivesFromBooleanExpression" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."BooleanExpression" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- RelationalExpression.ParameterType is an association to ParameterType: [1..1]
ALTER TABLE "Iteration_REPLACE"."RelationalExpression" ADD COLUMN "ParameterType" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."RelationalExpression" ADD CONSTRAINT "RelationalExpression_FK_ParameterType" FOREIGN KEY ("ParameterType") REFERENCES "SiteDirectory"."ParameterType" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- RelationalExpression.Scale is an optional association to MeasurementScale: [0..1]
ALTER TABLE "Iteration_REPLACE"."RelationalExpression" ADD COLUMN "Scale" uuid;
ALTER TABLE "Iteration_REPLACE"."RelationalExpression" ADD CONSTRAINT "RelationalExpression_FK_Scale" FOREIGN KEY ("Scale") REFERENCES "SiteDirectory"."MeasurementScale" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Class FileStore derives from Thing
ALTER TABLE "Iteration_REPLACE"."FileStore" ADD CONSTRAINT "FileStoreDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Folder is contained (composite) by FileStore: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Folder" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Folder" ADD CONSTRAINT "Folder_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."FileStore" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Folder_Container" ON "Iteration_REPLACE"."Folder" ("Container");
CREATE TRIGGER folder_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Folder"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- File is contained (composite) by FileStore: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."File" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."File" ADD CONSTRAINT "File_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."FileStore" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_File_Container" ON "Iteration_REPLACE"."File" ("Container");
CREATE TRIGGER file_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."File"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- FileStore.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."FileStore" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."FileStore" ADD CONSTRAINT "FileStore_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class DomainFileStore derives from FileStore
ALTER TABLE "Iteration_REPLACE"."DomainFileStore" ADD CONSTRAINT "DomainFileStoreDerivesFromFileStore" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."FileStore" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Folder derives from Thing
ALTER TABLE "Iteration_REPLACE"."Folder" ADD CONSTRAINT "FolderDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Folder.Creator is an association to Participant: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."Folder" ADD COLUMN "Creator" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Folder" ADD CONSTRAINT "Folder_FK_Creator" FOREIGN KEY ("Creator") REFERENCES "SiteDirectory"."Participant" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Folder.ContainingFolder is an optional association to Folder: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."Folder" ADD COLUMN "ContainingFolder" uuid;
ALTER TABLE "Iteration_REPLACE"."Folder" ADD CONSTRAINT "Folder_FK_ContainingFolder" FOREIGN KEY ("ContainingFolder") REFERENCES "Iteration_REPLACE"."Folder" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Folder.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."Folder" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Folder" ADD CONSTRAINT "Folder_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class File derives from Thing
ALTER TABLE "Iteration_REPLACE"."File" ADD CONSTRAINT "FileDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- File.LockedBy is an optional association to Person: [0..1]-[1..1]
ALTER TABLE "Iteration_REPLACE"."File" ADD COLUMN "LockedBy" uuid;
ALTER TABLE "Iteration_REPLACE"."File" ADD CONSTRAINT "File_FK_LockedBy" FOREIGN KEY ("LockedBy") REFERENCES "SiteDirectory"."Person" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- FileRevision is contained (composite) by File: [1..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."FileRevision" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."FileRevision" ADD CONSTRAINT "FileRevision_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."File" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_FileRevision_Container" ON "Iteration_REPLACE"."FileRevision" ("Container");
CREATE TRIGGER filerevision_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."FileRevision"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- File.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."File" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."File" ADD CONSTRAINT "File_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Category is a collection property (many to many) of class File: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."File_Category" (
  "File" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "File_Category_PK" PRIMARY KEY("File", "Category"),
  CONSTRAINT "File_Category_FK_Source" FOREIGN KEY ("File") REFERENCES "Iteration_REPLACE"."File" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "File_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."File_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_File_Category_ValidFrom" ON "Iteration_REPLACE"."File_Category" ("ValidFrom");
CREATE INDEX "Idx_File_Category_ValidTo" ON "Iteration_REPLACE"."File_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."File_Category_Audit" (LIKE "Iteration_REPLACE"."File_Category");
ALTER TABLE "Iteration_REPLACE"."File_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_File_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."File_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_File_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."File_Category_Audit" ("ValidTo");

CREATE TRIGGER File_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."File_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER File_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."File_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER file_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."File_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('File', 'EngineeringModel_REPLACE');
-- Class FileRevision derives from Thing
ALTER TABLE "Iteration_REPLACE"."FileRevision" ADD CONSTRAINT "FileRevisionDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- FileRevision.Creator is an association to Participant: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."FileRevision" ADD COLUMN "Creator" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."FileRevision" ADD CONSTRAINT "FileRevision_FK_Creator" FOREIGN KEY ("Creator") REFERENCES "SiteDirectory"."Participant" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- FileRevision.ContainingFolder is an optional association to Folder: [0..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."FileRevision" ADD COLUMN "ContainingFolder" uuid;
ALTER TABLE "Iteration_REPLACE"."FileRevision" ADD CONSTRAINT "FileRevision_FK_ContainingFolder" FOREIGN KEY ("ContainingFolder") REFERENCES "Iteration_REPLACE"."Folder" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- FileType is an ordered collection property (many to many) of class FileRevision: [1..*]-[0..*] (ordered)
CREATE TABLE "Iteration_REPLACE"."FileRevision_FileType" (
  "FileRevision" uuid NOT NULL,
  "FileType" uuid NOT NULL,
  "Sequence" bigint NOT NULL,
  CONSTRAINT "FileRevision_FileType_PK" PRIMARY KEY("FileRevision", "FileType"),
  CONSTRAINT "FileRevision_FileType_FK_Source" FOREIGN KEY ("FileRevision") REFERENCES "Iteration_REPLACE"."FileRevision" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "FileRevision_FileType_FK_Target" FOREIGN KEY ("FileType") REFERENCES "SiteDirectory"."FileType" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."FileRevision_FileType"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_FileRevision_FileType_ValidFrom" ON "Iteration_REPLACE"."FileRevision_FileType" ("ValidFrom");
CREATE INDEX "Idx_FileRevision_FileType_ValidTo" ON "Iteration_REPLACE"."FileRevision_FileType" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."FileRevision_FileType_Audit" (LIKE "Iteration_REPLACE"."FileRevision_FileType");
ALTER TABLE "Iteration_REPLACE"."FileRevision_FileType_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_FileRevision_FileTypeAudit_ValidFrom" ON "Iteration_REPLACE"."FileRevision_FileType_Audit" ("ValidFrom");
CREATE INDEX "Idx_FileRevision_FileTypeAudit_ValidTo" ON "Iteration_REPLACE"."FileRevision_FileType_Audit" ("ValidTo");

CREATE TRIGGER FileRevision_FileType_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."FileRevision_FileType"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER FileRevision_FileType_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."FileRevision_FileType"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER filerevision_filetype_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."FileRevision_FileType"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('FileRevision', 'EngineeringModel_REPLACE');
-- Class ActualFiniteStateList derives from Thing
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList" ADD CONSTRAINT "ActualFiniteStateListDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- PossibleFiniteStateList is an ordered collection property (many to many) of class ActualFiniteStateList: [1..*]-[0..*] (ordered)
CREATE TABLE "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList" (
  "ActualFiniteStateList" uuid NOT NULL,
  "PossibleFiniteStateList" uuid NOT NULL,
  "Sequence" bigint NOT NULL,
  CONSTRAINT "ActualFiniteStateList_PossibleFiniteStateList_PK" PRIMARY KEY("ActualFiniteStateList", "PossibleFiniteStateList"),
  CONSTRAINT "ActualFiniteStateList_PossibleFiniteStateList_FK_Source" FOREIGN KEY ("ActualFiniteStateList") REFERENCES "Iteration_REPLACE"."ActualFiniteStateList" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ActualFiniteStateList_PossibleFiniteStateList_FK_Target" FOREIGN KEY ("PossibleFiniteStateList") REFERENCES "Iteration_REPLACE"."PossibleFiniteStateList" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ActualFiniteStateList_PossibleFiniteStateList_ValidFrom" ON "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList" ("ValidFrom");
CREATE INDEX "Idx_ActualFiniteStateList_PossibleFiniteStateList_ValidTo" ON "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList_Audit" (LIKE "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList");
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ActualFiniteStateList_PossibleFiniteStateListAudit_ValidFrom" ON "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList_Audit" ("ValidFrom");
CREATE INDEX "Idx_ActualFiniteStateList_PossibleFiniteStateListAudit_ValidTo" ON "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList_Audit" ("ValidTo");

CREATE TRIGGER ActualFiniteStateList_PossibleFiniteStateList_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ActualFiniteStateList_PossibleFiniteStateList_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER actualfinitestatelist_possiblefinitestatelist_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ActualFiniteStateList', 'EngineeringModel_REPLACE');
-- ActualFiniteState is contained (composite) by ActualFiniteStateList: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."ActualFiniteState" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ActualFiniteState" ADD CONSTRAINT "ActualFiniteState_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."ActualFiniteStateList" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_ActualFiniteState_Container" ON "Iteration_REPLACE"."ActualFiniteState" ("Container");
CREATE TRIGGER actualfinitestate_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ActualFiniteState"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- ExcludeOption is a collection property (many to many) of class ActualFiniteStateList: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption" (
  "ActualFiniteStateList" uuid NOT NULL,
  "ExcludeOption" uuid NOT NULL,
  CONSTRAINT "ActualFiniteStateList_ExcludeOption_PK" PRIMARY KEY("ActualFiniteStateList", "ExcludeOption"),
  CONSTRAINT "ActualFiniteStateList_ExcludeOption_FK_Source" FOREIGN KEY ("ActualFiniteStateList") REFERENCES "Iteration_REPLACE"."ActualFiniteStateList" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ActualFiniteStateList_ExcludeOption_FK_Target" FOREIGN KEY ("ExcludeOption") REFERENCES "Iteration_REPLACE"."Option" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ActualFiniteStateList_ExcludeOption_ValidFrom" ON "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption" ("ValidFrom");
CREATE INDEX "Idx_ActualFiniteStateList_ExcludeOption_ValidTo" ON "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption_Audit" (LIKE "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption");
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ActualFiniteStateList_ExcludeOptionAudit_ValidFrom" ON "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption_Audit" ("ValidFrom");
CREATE INDEX "Idx_ActualFiniteStateList_ExcludeOptionAudit_ValidTo" ON "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption_Audit" ("ValidTo");

CREATE TRIGGER ActualFiniteStateList_ExcludeOption_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ActualFiniteStateList_ExcludeOption_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER actualfinitestatelist_excludeoption_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ActualFiniteStateList', 'EngineeringModel_REPLACE');
-- ActualFiniteStateList.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList" ADD CONSTRAINT "ActualFiniteStateList_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class ActualFiniteState derives from Thing
ALTER TABLE "Iteration_REPLACE"."ActualFiniteState" ADD CONSTRAINT "ActualFiniteStateDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- PossibleState is a collection property (many to many) of class ActualFiniteState: [1..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."ActualFiniteState_PossibleState" (
  "ActualFiniteState" uuid NOT NULL,
  "PossibleState" uuid NOT NULL,
  CONSTRAINT "ActualFiniteState_PossibleState_PK" PRIMARY KEY("ActualFiniteState", "PossibleState"),
  CONSTRAINT "ActualFiniteState_PossibleState_FK_Source" FOREIGN KEY ("ActualFiniteState") REFERENCES "Iteration_REPLACE"."ActualFiniteState" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ActualFiniteState_PossibleState_FK_Target" FOREIGN KEY ("PossibleState") REFERENCES "Iteration_REPLACE"."PossibleFiniteState" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."ActualFiniteState_PossibleState"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ActualFiniteState_PossibleState_ValidFrom" ON "Iteration_REPLACE"."ActualFiniteState_PossibleState" ("ValidFrom");
CREATE INDEX "Idx_ActualFiniteState_PossibleState_ValidTo" ON "Iteration_REPLACE"."ActualFiniteState_PossibleState" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ActualFiniteState_PossibleState_Audit" (LIKE "Iteration_REPLACE"."ActualFiniteState_PossibleState");
ALTER TABLE "Iteration_REPLACE"."ActualFiniteState_PossibleState_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ActualFiniteState_PossibleStateAudit_ValidFrom" ON "Iteration_REPLACE"."ActualFiniteState_PossibleState_Audit" ("ValidFrom");
CREATE INDEX "Idx_ActualFiniteState_PossibleStateAudit_ValidTo" ON "Iteration_REPLACE"."ActualFiniteState_PossibleState_Audit" ("ValidTo");

CREATE TRIGGER ActualFiniteState_PossibleState_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ActualFiniteState_PossibleState"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ActualFiniteState_PossibleState_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ActualFiniteState_PossibleState"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER actualfinitestate_possiblestate_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ActualFiniteState_PossibleState"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ActualFiniteState', 'EngineeringModel_REPLACE');
-- Class RuleVerificationList derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."RuleVerificationList" ADD CONSTRAINT "RuleVerificationListDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- RuleVerification is contained (composite) by RuleVerificationList: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."RuleVerification" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."RuleVerification" ADD CONSTRAINT "RuleVerification_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."RuleVerificationList" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_RuleVerification_Container" ON "Iteration_REPLACE"."RuleVerification" ("Container");
ALTER TABLE "Iteration_REPLACE"."RuleVerification" ADD COLUMN "Sequence" bigint NOT NULL;
CREATE TRIGGER ruleverification_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."RuleVerification"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- RuleVerificationList.Owner is an association to DomainOfExpertise: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."RuleVerificationList" ADD COLUMN "Owner" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."RuleVerificationList" ADD CONSTRAINT "RuleVerificationList_FK_Owner" FOREIGN KEY ("Owner") REFERENCES "SiteDirectory"."DomainOfExpertise" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class RuleVerification derives from Thing
ALTER TABLE "Iteration_REPLACE"."RuleVerification" ADD CONSTRAINT "RuleVerificationDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- RuleViolation is contained (composite) by RuleVerification: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."RuleViolation" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."RuleViolation" ADD CONSTRAINT "RuleViolation_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."RuleVerification" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_RuleViolation_Container" ON "Iteration_REPLACE"."RuleViolation" ("Container");
CREATE TRIGGER ruleviolation_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."RuleViolation"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class UserRuleVerification derives from RuleVerification
ALTER TABLE "Iteration_REPLACE"."UserRuleVerification" ADD CONSTRAINT "UserRuleVerificationDerivesFromRuleVerification" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."RuleVerification" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- UserRuleVerification.Rule is an association to Rule: [1..1]-[0..*]
ALTER TABLE "Iteration_REPLACE"."UserRuleVerification" ADD COLUMN "Rule" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."UserRuleVerification" ADD CONSTRAINT "UserRuleVerification_FK_Rule" FOREIGN KEY ("Rule") REFERENCES "SiteDirectory"."Rule" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class RuleViolation derives from Thing
ALTER TABLE "Iteration_REPLACE"."RuleViolation" ADD CONSTRAINT "RuleViolationDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- ViolatingThing is a collection property of class RuleViolation: [0..*]
CREATE TABLE "Iteration_REPLACE"."RuleViolation_ViolatingThing" (
  "RuleViolation" uuid NOT NULL,
  "ViolatingThing" uuid NOT NULL,
  CONSTRAINT "RuleViolation_ViolatingThing_PK" PRIMARY KEY("RuleViolation","ViolatingThing"),
  CONSTRAINT "RuleViolation_ViolatingThing_FK_Source" FOREIGN KEY ("RuleViolation") REFERENCES "Iteration_REPLACE"."RuleViolation" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);
ALTER TABLE "Iteration_REPLACE"."RuleViolation_ViolatingThing"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RuleViolation_ViolatingThing_ValidFrom" ON "Iteration_REPLACE"."RuleViolation_ViolatingThing" ("ValidFrom");
CREATE INDEX "Idx_RuleViolation_ViolatingThing_ValidTo" ON "Iteration_REPLACE"."RuleViolation_ViolatingThing" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RuleViolation_ViolatingThing_Audit" (LIKE "Iteration_REPLACE"."RuleViolation_ViolatingThing");
ALTER TABLE "Iteration_REPLACE"."RuleViolation_ViolatingThing_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RuleViolation_ViolatingThingAudit_ValidFrom" ON "Iteration_REPLACE"."RuleViolation_ViolatingThing_Audit" ("ValidFrom");
CREATE INDEX "Idx_RuleViolation_ViolatingThingAudit_ValidTo" ON "Iteration_REPLACE"."RuleViolation_ViolatingThing_Audit" ("ValidTo");

CREATE TRIGGER RuleViolation_ViolatingThing_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RuleViolation_ViolatingThing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RuleViolation_ViolatingThing_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RuleViolation_ViolatingThing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER ruleviolation_violatingthing_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."RuleViolation_ViolatingThing"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('RuleViolation', 'EngineeringModel_REPLACE');
-- Class BuiltInRuleVerification derives from RuleVerification
ALTER TABLE "Iteration_REPLACE"."BuiltInRuleVerification" ADD CONSTRAINT "BuiltInRuleVerificationDerivesFromRuleVerification" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."RuleVerification" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Stakeholder derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."Stakeholder" ADD CONSTRAINT "StakeholderDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- StakeholderValue is a collection property (many to many) of class Stakeholder: [0..*]-[1..1]
CREATE TABLE "Iteration_REPLACE"."Stakeholder_StakeholderValue" (
  "Stakeholder" uuid NOT NULL,
  "StakeholderValue" uuid NOT NULL,
  CONSTRAINT "Stakeholder_StakeholderValue_PK" PRIMARY KEY("Stakeholder", "StakeholderValue"),
  CONSTRAINT "Stakeholder_StakeholderValue_FK_Source" FOREIGN KEY ("Stakeholder") REFERENCES "Iteration_REPLACE"."Stakeholder" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Stakeholder_StakeholderValue_FK_Target" FOREIGN KEY ("StakeholderValue") REFERENCES "Iteration_REPLACE"."StakeholderValue" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."Stakeholder_StakeholderValue"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Stakeholder_StakeholderValue_ValidFrom" ON "Iteration_REPLACE"."Stakeholder_StakeholderValue" ("ValidFrom");
CREATE INDEX "Idx_Stakeholder_StakeholderValue_ValidTo" ON "Iteration_REPLACE"."Stakeholder_StakeholderValue" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Stakeholder_StakeholderValue_Audit" (LIKE "Iteration_REPLACE"."Stakeholder_StakeholderValue");
ALTER TABLE "Iteration_REPLACE"."Stakeholder_StakeholderValue_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Stakeholder_StakeholderValueAudit_ValidFrom" ON "Iteration_REPLACE"."Stakeholder_StakeholderValue_Audit" ("ValidFrom");
CREATE INDEX "Idx_Stakeholder_StakeholderValueAudit_ValidTo" ON "Iteration_REPLACE"."Stakeholder_StakeholderValue_Audit" ("ValidTo");

CREATE TRIGGER Stakeholder_StakeholderValue_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Stakeholder_StakeholderValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Stakeholder_StakeholderValue_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Stakeholder_StakeholderValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER stakeholder_stakeholdervalue_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Stakeholder_StakeholderValue"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Stakeholder', 'EngineeringModel_REPLACE');
-- Category is a collection property (many to many) of class Stakeholder: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."Stakeholder_Category" (
  "Stakeholder" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "Stakeholder_Category_PK" PRIMARY KEY("Stakeholder", "Category"),
  CONSTRAINT "Stakeholder_Category_FK_Source" FOREIGN KEY ("Stakeholder") REFERENCES "Iteration_REPLACE"."Stakeholder" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Stakeholder_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."Stakeholder_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Stakeholder_Category_ValidFrom" ON "Iteration_REPLACE"."Stakeholder_Category" ("ValidFrom");
CREATE INDEX "Idx_Stakeholder_Category_ValidTo" ON "Iteration_REPLACE"."Stakeholder_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Stakeholder_Category_Audit" (LIKE "Iteration_REPLACE"."Stakeholder_Category");
ALTER TABLE "Iteration_REPLACE"."Stakeholder_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Stakeholder_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."Stakeholder_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_Stakeholder_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."Stakeholder_Category_Audit" ("ValidTo");

CREATE TRIGGER Stakeholder_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Stakeholder_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Stakeholder_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Stakeholder_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER stakeholder_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Stakeholder_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Stakeholder', 'EngineeringModel_REPLACE');
-- Class Goal derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."Goal" ADD CONSTRAINT "GoalDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Category is a collection property (many to many) of class Goal: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."Goal_Category" (
  "Goal" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "Goal_Category_PK" PRIMARY KEY("Goal", "Category"),
  CONSTRAINT "Goal_Category_FK_Source" FOREIGN KEY ("Goal") REFERENCES "Iteration_REPLACE"."Goal" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "Goal_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."Goal_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Goal_Category_ValidFrom" ON "Iteration_REPLACE"."Goal_Category" ("ValidFrom");
CREATE INDEX "Idx_Goal_Category_ValidTo" ON "Iteration_REPLACE"."Goal_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Goal_Category_Audit" (LIKE "Iteration_REPLACE"."Goal_Category");
ALTER TABLE "Iteration_REPLACE"."Goal_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_Goal_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."Goal_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_Goal_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."Goal_Category_Audit" ("ValidTo");

CREATE TRIGGER Goal_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Goal_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Goal_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Goal_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER goal_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Goal_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Goal', 'EngineeringModel_REPLACE');
-- Class ValueGroup derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."ValueGroup" ADD CONSTRAINT "ValueGroupDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Category is a collection property (many to many) of class ValueGroup: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."ValueGroup_Category" (
  "ValueGroup" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "ValueGroup_Category_PK" PRIMARY KEY("ValueGroup", "Category"),
  CONSTRAINT "ValueGroup_Category_FK_Source" FOREIGN KEY ("ValueGroup") REFERENCES "Iteration_REPLACE"."ValueGroup" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "ValueGroup_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."ValueGroup_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ValueGroup_Category_ValidFrom" ON "Iteration_REPLACE"."ValueGroup_Category" ("ValidFrom");
CREATE INDEX "Idx_ValueGroup_Category_ValidTo" ON "Iteration_REPLACE"."ValueGroup_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ValueGroup_Category_Audit" (LIKE "Iteration_REPLACE"."ValueGroup_Category");
ALTER TABLE "Iteration_REPLACE"."ValueGroup_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ValueGroup_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."ValueGroup_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_ValueGroup_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."ValueGroup_Category_Audit" ("ValidTo");

CREATE TRIGGER ValueGroup_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ValueGroup_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ValueGroup_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ValueGroup_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER valuegroup_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."ValueGroup_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('ValueGroup', 'EngineeringModel_REPLACE');
-- Class StakeholderValue derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."StakeholderValue" ADD CONSTRAINT "StakeholderValueDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Category is a collection property (many to many) of class StakeholderValue: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."StakeholderValue_Category" (
  "StakeholderValue" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "StakeholderValue_Category_PK" PRIMARY KEY("StakeholderValue", "Category"),
  CONSTRAINT "StakeholderValue_Category_FK_Source" FOREIGN KEY ("StakeholderValue") REFERENCES "Iteration_REPLACE"."StakeholderValue" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "StakeholderValue_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."StakeholderValue_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_StakeholderValue_Category_ValidFrom" ON "Iteration_REPLACE"."StakeholderValue_Category" ("ValidFrom");
CREATE INDEX "Idx_StakeholderValue_Category_ValidTo" ON "Iteration_REPLACE"."StakeholderValue_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."StakeholderValue_Category_Audit" (LIKE "Iteration_REPLACE"."StakeholderValue_Category");
ALTER TABLE "Iteration_REPLACE"."StakeholderValue_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_StakeholderValue_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."StakeholderValue_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_StakeholderValue_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."StakeholderValue_Category_Audit" ("ValidTo");

CREATE TRIGGER StakeholderValue_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."StakeholderValue_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER StakeholderValue_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."StakeholderValue_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER stakeholdervalue_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."StakeholderValue_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('StakeholderValue', 'EngineeringModel_REPLACE');
-- Class StakeHolderValueMap derives from DefinedThing
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap" ADD CONSTRAINT "StakeHolderValueMapDerivesFromDefinedThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DefinedThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Goal is a collection property (many to many) of class StakeHolderValueMap: [0..*]-[1..1]
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_Goal" (
  "StakeHolderValueMap" uuid NOT NULL,
  "Goal" uuid NOT NULL,
  CONSTRAINT "StakeHolderValueMap_Goal_PK" PRIMARY KEY("StakeHolderValueMap", "Goal"),
  CONSTRAINT "StakeHolderValueMap_Goal_FK_Source" FOREIGN KEY ("StakeHolderValueMap") REFERENCES "Iteration_REPLACE"."StakeHolderValueMap" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "StakeHolderValueMap_Goal_FK_Target" FOREIGN KEY ("Goal") REFERENCES "Iteration_REPLACE"."Goal" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_Goal"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_StakeHolderValueMap_Goal_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_Goal" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_Goal_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_Goal" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_Goal_Audit" (LIKE "Iteration_REPLACE"."StakeHolderValueMap_Goal");
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_Goal_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_StakeHolderValueMap_GoalAudit_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_Goal_Audit" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_GoalAudit_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_Goal_Audit" ("ValidTo");

CREATE TRIGGER StakeHolderValueMap_Goal_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."StakeHolderValueMap_Goal"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER StakeHolderValueMap_Goal_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."StakeHolderValueMap_Goal"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER stakeholdervaluemap_goal_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."StakeHolderValueMap_Goal"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('StakeHolderValueMap', 'EngineeringModel_REPLACE');
-- ValueGroup is a collection property (many to many) of class StakeHolderValueMap: [0..*]-[1..1]
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup" (
  "StakeHolderValueMap" uuid NOT NULL,
  "ValueGroup" uuid NOT NULL,
  CONSTRAINT "StakeHolderValueMap_ValueGroup_PK" PRIMARY KEY("StakeHolderValueMap", "ValueGroup"),
  CONSTRAINT "StakeHolderValueMap_ValueGroup_FK_Source" FOREIGN KEY ("StakeHolderValueMap") REFERENCES "Iteration_REPLACE"."StakeHolderValueMap" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "StakeHolderValueMap_ValueGroup_FK_Target" FOREIGN KEY ("ValueGroup") REFERENCES "Iteration_REPLACE"."ValueGroup" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_StakeHolderValueMap_ValueGroup_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_ValueGroup_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup_Audit" (LIKE "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup");
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_StakeHolderValueMap_ValueGroupAudit_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup_Audit" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_ValueGroupAudit_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup_Audit" ("ValidTo");

CREATE TRIGGER StakeHolderValueMap_ValueGroup_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER StakeHolderValueMap_ValueGroup_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER stakeholdervaluemap_valuegroup_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('StakeHolderValueMap', 'EngineeringModel_REPLACE');
-- StakeholderValue is a collection property (many to many) of class StakeHolderValueMap: [0..*]-[1..1]
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue" (
  "StakeHolderValueMap" uuid NOT NULL,
  "StakeholderValue" uuid NOT NULL,
  CONSTRAINT "StakeHolderValueMap_StakeholderValue_PK" PRIMARY KEY("StakeHolderValueMap", "StakeholderValue"),
  CONSTRAINT "StakeHolderValueMap_StakeholderValue_FK_Source" FOREIGN KEY ("StakeHolderValueMap") REFERENCES "Iteration_REPLACE"."StakeHolderValueMap" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "StakeHolderValueMap_StakeholderValue_FK_Target" FOREIGN KEY ("StakeholderValue") REFERENCES "Iteration_REPLACE"."StakeholderValue" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_StakeHolderValueMap_StakeholderValue_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_StakeholderValue_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue_Audit" (LIKE "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue");
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_StakeHolderValueMap_StakeholderValueAudit_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue_Audit" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_StakeholderValueAudit_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue_Audit" ("ValidTo");

CREATE TRIGGER StakeHolderValueMap_StakeholderValue_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER StakeHolderValueMap_StakeholderValue_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER stakeholdervaluemap_stakeholdervalue_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('StakeHolderValueMap', 'EngineeringModel_REPLACE');
-- StakeHolderValueMapSettings is contained (composite) by StakeHolderValueMap: [1..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings" ADD CONSTRAINT "StakeHolderValueMapSettings_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."StakeHolderValueMap" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_StakeHolderValueMapSettings_Container" ON "Iteration_REPLACE"."StakeHolderValueMapSettings" ("Container");
CREATE TRIGGER stakeholdervaluemapsettings_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."StakeHolderValueMapSettings"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Requirement is a collection property (many to many) of class StakeHolderValueMap: [0..*]-[1..1]
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_Requirement" (
  "StakeHolderValueMap" uuid NOT NULL,
  "Requirement" uuid NOT NULL,
  CONSTRAINT "StakeHolderValueMap_Requirement_PK" PRIMARY KEY("StakeHolderValueMap", "Requirement"),
  CONSTRAINT "StakeHolderValueMap_Requirement_FK_Source" FOREIGN KEY ("StakeHolderValueMap") REFERENCES "Iteration_REPLACE"."StakeHolderValueMap" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "StakeHolderValueMap_Requirement_FK_Target" FOREIGN KEY ("Requirement") REFERENCES "Iteration_REPLACE"."Requirement" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_Requirement"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_StakeHolderValueMap_Requirement_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_Requirement" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_Requirement_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_Requirement" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_Requirement_Audit" (LIKE "Iteration_REPLACE"."StakeHolderValueMap_Requirement");
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_Requirement_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_StakeHolderValueMap_RequirementAudit_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_Requirement_Audit" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_RequirementAudit_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_Requirement_Audit" ("ValidTo");

CREATE TRIGGER StakeHolderValueMap_Requirement_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."StakeHolderValueMap_Requirement"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER StakeHolderValueMap_Requirement_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."StakeHolderValueMap_Requirement"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER stakeholdervaluemap_requirement_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."StakeHolderValueMap_Requirement"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('StakeHolderValueMap', 'EngineeringModel_REPLACE');
-- Category is a collection property (many to many) of class StakeHolderValueMap: [0..*]-[0..*]
CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_Category" (
  "StakeHolderValueMap" uuid NOT NULL,
  "Category" uuid NOT NULL,
  CONSTRAINT "StakeHolderValueMap_Category_PK" PRIMARY KEY("StakeHolderValueMap", "Category"),
  CONSTRAINT "StakeHolderValueMap_Category_FK_Source" FOREIGN KEY ("StakeHolderValueMap") REFERENCES "Iteration_REPLACE"."StakeHolderValueMap" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE,
  CONSTRAINT "StakeHolderValueMap_Category_FK_Target" FOREIGN KEY ("Category") REFERENCES "SiteDirectory"."Category" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE
);
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_Category"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_StakeHolderValueMap_Category_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_Category" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_Category_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_Category" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_Category_Audit" (LIKE "Iteration_REPLACE"."StakeHolderValueMap_Category");
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_Category_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_StakeHolderValueMap_CategoryAudit_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_Category_Audit" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_CategoryAudit_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_Category_Audit" ("ValidTo");

CREATE TRIGGER StakeHolderValueMap_Category_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."StakeHolderValueMap_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER StakeHolderValueMap_Category_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."StakeHolderValueMap_Category"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE TRIGGER stakeholdervaluemap_category_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."StakeHolderValueMap_Category"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('StakeHolderValueMap', 'EngineeringModel_REPLACE');
-- Class StakeHolderValueMapSettings derives from Thing
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings" ADD CONSTRAINT "StakeHolderValueMapSettingsDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- StakeHolderValueMapSettings.GoalToValueGroupRelationship is an optional association to BinaryRelationshipRule: [0..1]
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings" ADD COLUMN "GoalToValueGroupRelationship" uuid;
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings" ADD CONSTRAINT "StakeHolderValueMapSettings_FK_GoalToValueGroupRelationship" FOREIGN KEY ("GoalToValueGroupRelationship") REFERENCES "SiteDirectory"."BinaryRelationshipRule" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- StakeHolderValueMapSettings.ValueGroupToStakeholderValueRelationship is an optional association to BinaryRelationshipRule: [0..1]
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings" ADD COLUMN "ValueGroupToStakeholderValueRelationship" uuid;
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings" ADD CONSTRAINT "StakeHolderValueMapSettings_FK_ValueGroupToStakeholderValueRelationship" FOREIGN KEY ("ValueGroupToStakeholderValueRelationship") REFERENCES "SiteDirectory"."BinaryRelationshipRule" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- StakeHolderValueMapSettings.StakeholderValueToRequirementRelationship is an optional association to BinaryRelationshipRule: [0..1]
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings" ADD COLUMN "StakeholderValueToRequirementRelationship" uuid;
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings" ADD CONSTRAINT "StakeHolderValueMapSettings_FK_StakeholderValueToRequirementRelationship" FOREIGN KEY ("StakeholderValueToRequirementRelationship") REFERENCES "SiteDirectory"."BinaryRelationshipRule" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Class DiagramThingBase derives from Thing
ALTER TABLE "Iteration_REPLACE"."DiagramThingBase" ADD CONSTRAINT "DiagramThingBaseDerivesFromThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class DiagrammingStyle derives from DiagramThingBase
ALTER TABLE "Iteration_REPLACE"."DiagrammingStyle" ADD CONSTRAINT "DiagrammingStyleDerivesFromDiagramThingBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagramThingBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- DiagrammingStyle.FillColor is an optional association to Color: [0..1]
ALTER TABLE "Iteration_REPLACE"."DiagrammingStyle" ADD COLUMN "FillColor" uuid;
ALTER TABLE "Iteration_REPLACE"."DiagrammingStyle" ADD CONSTRAINT "DiagrammingStyle_FK_FillColor" FOREIGN KEY ("FillColor") REFERENCES "Iteration_REPLACE"."Color" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- DiagrammingStyle.StrokeColor is an optional association to Color: [0..1]
ALTER TABLE "Iteration_REPLACE"."DiagrammingStyle" ADD COLUMN "StrokeColor" uuid;
ALTER TABLE "Iteration_REPLACE"."DiagrammingStyle" ADD CONSTRAINT "DiagrammingStyle_FK_StrokeColor" FOREIGN KEY ("StrokeColor") REFERENCES "Iteration_REPLACE"."Color" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- DiagrammingStyle.FontColor is an optional association to Color: [0..1]
ALTER TABLE "Iteration_REPLACE"."DiagrammingStyle" ADD COLUMN "FontColor" uuid;
ALTER TABLE "Iteration_REPLACE"."DiagrammingStyle" ADD CONSTRAINT "DiagrammingStyle_FK_FontColor" FOREIGN KEY ("FontColor") REFERENCES "Iteration_REPLACE"."Color" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Color is contained (composite) by DiagrammingStyle: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Color" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Color" ADD CONSTRAINT "Color_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."DiagrammingStyle" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Color_Container" ON "Iteration_REPLACE"."Color" ("Container");
CREATE TRIGGER color_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Color"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class SharedStyle derives from DiagrammingStyle
ALTER TABLE "Iteration_REPLACE"."SharedStyle" ADD CONSTRAINT "SharedStyleDerivesFromDiagrammingStyle" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagrammingStyle" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Color derives from DiagramThingBase
ALTER TABLE "Iteration_REPLACE"."Color" ADD CONSTRAINT "ColorDerivesFromDiagramThingBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagramThingBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class DiagramElementContainer derives from DiagramThingBase
ALTER TABLE "Iteration_REPLACE"."DiagramElementContainer" ADD CONSTRAINT "DiagramElementContainerDerivesFromDiagramThingBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagramThingBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- DiagramElementThing is contained (composite) by DiagramElementContainer: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."DiagramElementThing" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."DiagramElementThing" ADD CONSTRAINT "DiagramElementThing_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."DiagramElementContainer" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_DiagramElementThing_Container" ON "Iteration_REPLACE"."DiagramElementThing" ("Container");
CREATE TRIGGER diagramelementthing_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."DiagramElementThing"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Bounds is contained (composite) by DiagramElementContainer: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Bounds" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Bounds" ADD CONSTRAINT "Bounds_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."DiagramElementContainer" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Bounds_Container" ON "Iteration_REPLACE"."Bounds" ("Container");
CREATE TRIGGER bounds_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Bounds"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class DiagramCanvas derives from DiagramElementContainer
ALTER TABLE "Iteration_REPLACE"."DiagramCanvas" ADD CONSTRAINT "DiagramCanvasDerivesFromDiagramElementContainer" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagramElementContainer" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class DiagramElementThing derives from DiagramElementContainer
ALTER TABLE "Iteration_REPLACE"."DiagramElementThing" ADD CONSTRAINT "DiagramElementThingDerivesFromDiagramElementContainer" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagramElementContainer" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- DiagramElementThing.DepictedThing is an optional association to Thing: [0..1]-[1..1]
ALTER TABLE "Iteration_REPLACE"."DiagramElementThing" ADD COLUMN "DepictedThing" uuid;
ALTER TABLE "Iteration_REPLACE"."DiagramElementThing" ADD CONSTRAINT "DiagramElementThing_FK_DepictedThing" FOREIGN KEY ("DepictedThing") REFERENCES "Iteration_REPLACE"."Thing" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- OwnedStyle is contained (composite) by DiagramElementThing: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."OwnedStyle" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."OwnedStyle" ADD CONSTRAINT "OwnedStyle_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."DiagramElementThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_OwnedStyle_Container" ON "Iteration_REPLACE"."OwnedStyle" ("Container");
CREATE TRIGGER ownedstyle_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."OwnedStyle"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- DiagramElementThing.SharedStyle is an optional association to SharedStyle: [0..1]-[1..1]
ALTER TABLE "Iteration_REPLACE"."DiagramElementThing" ADD COLUMN "SharedStyle" uuid;
ALTER TABLE "Iteration_REPLACE"."DiagramElementThing" ADD CONSTRAINT "DiagramElementThing_FK_SharedStyle" FOREIGN KEY ("SharedStyle") REFERENCES "Iteration_REPLACE"."SharedStyle" ("Iid") ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE;
-- Class DiagramEdge derives from DiagramElementThing
ALTER TABLE "Iteration_REPLACE"."DiagramEdge" ADD CONSTRAINT "DiagramEdgeDerivesFromDiagramElementThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagramElementThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- DiagramEdge.Source is an association to DiagramElementThing: [1..1]-[1..1]
ALTER TABLE "Iteration_REPLACE"."DiagramEdge" ADD COLUMN "Source" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."DiagramEdge" ADD CONSTRAINT "DiagramEdge_FK_Source" FOREIGN KEY ("Source") REFERENCES "Iteration_REPLACE"."DiagramElementThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- DiagramEdge.Target is an association to DiagramElementThing: [1..1]-[1..1]
ALTER TABLE "Iteration_REPLACE"."DiagramEdge" ADD COLUMN "Target" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."DiagramEdge" ADD CONSTRAINT "DiagramEdge_FK_Target" FOREIGN KEY ("Target") REFERENCES "Iteration_REPLACE"."DiagramElementThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Point is contained (composite) by DiagramEdge: [0..*]-[1..1]
ALTER TABLE "Iteration_REPLACE"."Point" ADD COLUMN "Container" uuid NOT NULL;
ALTER TABLE "Iteration_REPLACE"."Point" ADD CONSTRAINT "Point_FK_Container" FOREIGN KEY ("Container") REFERENCES "Iteration_REPLACE"."DiagramEdge" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- add index on container
CREATE INDEX "Idx_Point_Container" ON "Iteration_REPLACE"."Point" ("Container");
ALTER TABLE "Iteration_REPLACE"."Point" ADD COLUMN "Sequence" bigint NOT NULL;
CREATE TRIGGER point_apply_revision
  BEFORE INSERT OR UPDATE OR DELETE 
  ON "Iteration_REPLACE"."Point"
  FOR EACH ROW
  EXECUTE PROCEDURE "SiteDirectory".revision_management('Container', 'EngineeringModel_REPLACE', 'Iteration_REPLACE');
-- Class Bounds derives from DiagramThingBase
ALTER TABLE "Iteration_REPLACE"."Bounds" ADD CONSTRAINT "BoundsDerivesFromDiagramThingBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagramThingBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class OwnedStyle derives from DiagrammingStyle
ALTER TABLE "Iteration_REPLACE"."OwnedStyle" ADD CONSTRAINT "OwnedStyleDerivesFromDiagrammingStyle" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagrammingStyle" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class Point derives from DiagramThingBase
ALTER TABLE "Iteration_REPLACE"."Point" ADD CONSTRAINT "PointDerivesFromDiagramThingBase" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagramThingBase" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class DiagramShape derives from DiagramElementThing
ALTER TABLE "Iteration_REPLACE"."DiagramShape" ADD CONSTRAINT "DiagramShapeDerivesFromDiagramElementThing" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagramElementThing" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
-- Class DiagramObject derives from DiagramShape
ALTER TABLE "Iteration_REPLACE"."DiagramObject" ADD CONSTRAINT "DiagramObjectDerivesFromDiagramShape" FOREIGN KEY ("Iid") REFERENCES "Iteration_REPLACE"."DiagramShape" ("Iid") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE;
ALTER TABLE "EngineeringModel_REPLACE"."Thing"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Thing_ValidFrom" ON "EngineeringModel_REPLACE"."Thing" ("ValidFrom");
CREATE INDEX "Idx_Thing_ValidTo" ON "EngineeringModel_REPLACE"."Thing" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Thing_Audit" (LIKE "EngineeringModel_REPLACE"."Thing");
ALTER TABLE "EngineeringModel_REPLACE"."Thing_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ThingAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Thing_Audit" ("ValidFrom");
CREATE INDEX "Idx_ThingAudit_ValidTo" ON "EngineeringModel_REPLACE"."Thing_Audit" ("ValidTo");

CREATE TRIGGER Thing_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Thing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Thing_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Thing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."TopContainer"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_TopContainer_ValidFrom" ON "EngineeringModel_REPLACE"."TopContainer" ("ValidFrom");
CREATE INDEX "Idx_TopContainer_ValidTo" ON "EngineeringModel_REPLACE"."TopContainer" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."TopContainer_Audit" (LIKE "EngineeringModel_REPLACE"."TopContainer");
ALTER TABLE "EngineeringModel_REPLACE"."TopContainer_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_TopContainerAudit_ValidFrom" ON "EngineeringModel_REPLACE"."TopContainer_Audit" ("ValidFrom");
CREATE INDEX "Idx_TopContainerAudit_ValidTo" ON "EngineeringModel_REPLACE"."TopContainer_Audit" ("ValidTo");

CREATE TRIGGER TopContainer_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."TopContainer"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER TopContainer_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."TopContainer"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModel"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_EngineeringModel_ValidFrom" ON "EngineeringModel_REPLACE"."EngineeringModel" ("ValidFrom");
CREATE INDEX "Idx_EngineeringModel_ValidTo" ON "EngineeringModel_REPLACE"."EngineeringModel" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModel_Audit" (LIKE "EngineeringModel_REPLACE"."EngineeringModel");
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModel_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_EngineeringModelAudit_ValidFrom" ON "EngineeringModel_REPLACE"."EngineeringModel_Audit" ("ValidFrom");
CREATE INDEX "Idx_EngineeringModelAudit_ValidTo" ON "EngineeringModel_REPLACE"."EngineeringModel_Audit" ("ValidTo");

CREATE TRIGGER EngineeringModel_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."EngineeringModel"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER EngineeringModel_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."EngineeringModel"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."FileStore"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_FileStore_ValidFrom" ON "EngineeringModel_REPLACE"."FileStore" ("ValidFrom");
CREATE INDEX "Idx_FileStore_ValidTo" ON "EngineeringModel_REPLACE"."FileStore" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."FileStore_Audit" (LIKE "EngineeringModel_REPLACE"."FileStore");
ALTER TABLE "EngineeringModel_REPLACE"."FileStore_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_FileStoreAudit_ValidFrom" ON "EngineeringModel_REPLACE"."FileStore_Audit" ("ValidFrom");
CREATE INDEX "Idx_FileStoreAudit_ValidTo" ON "EngineeringModel_REPLACE"."FileStore_Audit" ("ValidTo");

CREATE TRIGGER FileStore_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."FileStore"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER FileStore_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."FileStore"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."CommonFileStore"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_CommonFileStore_ValidFrom" ON "EngineeringModel_REPLACE"."CommonFileStore" ("ValidFrom");
CREATE INDEX "Idx_CommonFileStore_ValidTo" ON "EngineeringModel_REPLACE"."CommonFileStore" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."CommonFileStore_Audit" (LIKE "EngineeringModel_REPLACE"."CommonFileStore");
ALTER TABLE "EngineeringModel_REPLACE"."CommonFileStore_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_CommonFileStoreAudit_ValidFrom" ON "EngineeringModel_REPLACE"."CommonFileStore_Audit" ("ValidFrom");
CREATE INDEX "Idx_CommonFileStoreAudit_ValidTo" ON "EngineeringModel_REPLACE"."CommonFileStore_Audit" ("ValidTo");

CREATE TRIGGER CommonFileStore_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."CommonFileStore"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER CommonFileStore_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."CommonFileStore"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."Folder"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Folder_ValidFrom" ON "EngineeringModel_REPLACE"."Folder" ("ValidFrom");
CREATE INDEX "Idx_Folder_ValidTo" ON "EngineeringModel_REPLACE"."Folder" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Folder_Audit" (LIKE "EngineeringModel_REPLACE"."Folder");
ALTER TABLE "EngineeringModel_REPLACE"."Folder_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_FolderAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Folder_Audit" ("ValidFrom");
CREATE INDEX "Idx_FolderAudit_ValidTo" ON "EngineeringModel_REPLACE"."Folder_Audit" ("ValidTo");

CREATE TRIGGER Folder_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Folder"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Folder_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Folder"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."File"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_File_ValidFrom" ON "EngineeringModel_REPLACE"."File" ("ValidFrom");
CREATE INDEX "Idx_File_ValidTo" ON "EngineeringModel_REPLACE"."File" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."File_Audit" (LIKE "EngineeringModel_REPLACE"."File");
ALTER TABLE "EngineeringModel_REPLACE"."File_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_FileAudit_ValidFrom" ON "EngineeringModel_REPLACE"."File_Audit" ("ValidFrom");
CREATE INDEX "Idx_FileAudit_ValidTo" ON "EngineeringModel_REPLACE"."File_Audit" ("ValidTo");

CREATE TRIGGER File_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."File"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER File_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."File"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_FileRevision_ValidFrom" ON "EngineeringModel_REPLACE"."FileRevision" ("ValidFrom");
CREATE INDEX "Idx_FileRevision_ValidTo" ON "EngineeringModel_REPLACE"."FileRevision" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."FileRevision_Audit" (LIKE "EngineeringModel_REPLACE"."FileRevision");
ALTER TABLE "EngineeringModel_REPLACE"."FileRevision_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_FileRevisionAudit_ValidFrom" ON "EngineeringModel_REPLACE"."FileRevision_Audit" ("ValidFrom");
CREATE INDEX "Idx_FileRevisionAudit_ValidTo" ON "EngineeringModel_REPLACE"."FileRevision_Audit" ("ValidTo");

CREATE TRIGGER FileRevision_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."FileRevision"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER FileRevision_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."FileRevision"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ModelLogEntry_ValidFrom" ON "EngineeringModel_REPLACE"."ModelLogEntry" ("ValidFrom");
CREATE INDEX "Idx_ModelLogEntry_ValidTo" ON "EngineeringModel_REPLACE"."ModelLogEntry" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ModelLogEntry_Audit" (LIKE "EngineeringModel_REPLACE"."ModelLogEntry");
ALTER TABLE "EngineeringModel_REPLACE"."ModelLogEntry_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ModelLogEntryAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ModelLogEntry_Audit" ("ValidFrom");
CREATE INDEX "Idx_ModelLogEntryAudit_ValidTo" ON "EngineeringModel_REPLACE"."ModelLogEntry_Audit" ("ValidTo");

CREATE TRIGGER ModelLogEntry_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ModelLogEntry"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ModelLogEntry_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ModelLogEntry"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."Iteration"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Iteration_ValidFrom" ON "EngineeringModel_REPLACE"."Iteration" ("ValidFrom");
CREATE INDEX "Idx_Iteration_ValidTo" ON "EngineeringModel_REPLACE"."Iteration" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Iteration_Audit" (LIKE "EngineeringModel_REPLACE"."Iteration");
ALTER TABLE "EngineeringModel_REPLACE"."Iteration_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_IterationAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Iteration_Audit" ("ValidFrom");
CREATE INDEX "Idx_IterationAudit_ValidTo" ON "EngineeringModel_REPLACE"."Iteration_Audit" ("ValidTo");

CREATE TRIGGER Iteration_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Iteration"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Iteration_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Iteration"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."Book"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Book_ValidFrom" ON "EngineeringModel_REPLACE"."Book" ("ValidFrom");
CREATE INDEX "Idx_Book_ValidTo" ON "EngineeringModel_REPLACE"."Book" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Book_Audit" (LIKE "EngineeringModel_REPLACE"."Book");
ALTER TABLE "EngineeringModel_REPLACE"."Book_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_BookAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Book_Audit" ("ValidFrom");
CREATE INDEX "Idx_BookAudit_ValidTo" ON "EngineeringModel_REPLACE"."Book_Audit" ("ValidTo");

CREATE TRIGGER Book_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Book"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Book_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Book"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."Section"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Section_ValidFrom" ON "EngineeringModel_REPLACE"."Section" ("ValidFrom");
CREATE INDEX "Idx_Section_ValidTo" ON "EngineeringModel_REPLACE"."Section" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Section_Audit" (LIKE "EngineeringModel_REPLACE"."Section");
ALTER TABLE "EngineeringModel_REPLACE"."Section_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_SectionAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Section_Audit" ("ValidFrom");
CREATE INDEX "Idx_SectionAudit_ValidTo" ON "EngineeringModel_REPLACE"."Section_Audit" ("ValidTo");

CREATE TRIGGER Section_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Section"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Section_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Section"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."Page"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Page_ValidFrom" ON "EngineeringModel_REPLACE"."Page" ("ValidFrom");
CREATE INDEX "Idx_Page_ValidTo" ON "EngineeringModel_REPLACE"."Page" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Page_Audit" (LIKE "EngineeringModel_REPLACE"."Page");
ALTER TABLE "EngineeringModel_REPLACE"."Page_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_PageAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Page_Audit" ("ValidFrom");
CREATE INDEX "Idx_PageAudit_ValidTo" ON "EngineeringModel_REPLACE"."Page_Audit" ("ValidTo");

CREATE TRIGGER Page_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Page"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Page_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Page"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."Note"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Note_ValidFrom" ON "EngineeringModel_REPLACE"."Note" ("ValidFrom");
CREATE INDEX "Idx_Note_ValidTo" ON "EngineeringModel_REPLACE"."Note" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Note_Audit" (LIKE "EngineeringModel_REPLACE"."Note");
ALTER TABLE "EngineeringModel_REPLACE"."Note_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_NoteAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Note_Audit" ("ValidFrom");
CREATE INDEX "Idx_NoteAudit_ValidTo" ON "EngineeringModel_REPLACE"."Note_Audit" ("ValidTo");

CREATE TRIGGER Note_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Note"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Note_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Note"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."BinaryNote"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_BinaryNote_ValidFrom" ON "EngineeringModel_REPLACE"."BinaryNote" ("ValidFrom");
CREATE INDEX "Idx_BinaryNote_ValidTo" ON "EngineeringModel_REPLACE"."BinaryNote" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."BinaryNote_Audit" (LIKE "EngineeringModel_REPLACE"."BinaryNote");
ALTER TABLE "EngineeringModel_REPLACE"."BinaryNote_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_BinaryNoteAudit_ValidFrom" ON "EngineeringModel_REPLACE"."BinaryNote_Audit" ("ValidFrom");
CREATE INDEX "Idx_BinaryNoteAudit_ValidTo" ON "EngineeringModel_REPLACE"."BinaryNote_Audit" ("ValidTo");

CREATE TRIGGER BinaryNote_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."BinaryNote"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER BinaryNote_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."BinaryNote"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."TextualNote"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_TextualNote_ValidFrom" ON "EngineeringModel_REPLACE"."TextualNote" ("ValidFrom");
CREATE INDEX "Idx_TextualNote_ValidTo" ON "EngineeringModel_REPLACE"."TextualNote" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."TextualNote_Audit" (LIKE "EngineeringModel_REPLACE"."TextualNote");
ALTER TABLE "EngineeringModel_REPLACE"."TextualNote_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_TextualNoteAudit_ValidFrom" ON "EngineeringModel_REPLACE"."TextualNote_Audit" ("ValidFrom");
CREATE INDEX "Idx_TextualNoteAudit_ValidTo" ON "EngineeringModel_REPLACE"."TextualNote_Audit" ("ValidTo");

CREATE TRIGGER TextualNote_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."TextualNote"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER TextualNote_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."TextualNote"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."GenericAnnotation"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_GenericAnnotation_ValidFrom" ON "EngineeringModel_REPLACE"."GenericAnnotation" ("ValidFrom");
CREATE INDEX "Idx_GenericAnnotation_ValidTo" ON "EngineeringModel_REPLACE"."GenericAnnotation" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."GenericAnnotation_Audit" (LIKE "EngineeringModel_REPLACE"."GenericAnnotation");
ALTER TABLE "EngineeringModel_REPLACE"."GenericAnnotation_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_GenericAnnotationAudit_ValidFrom" ON "EngineeringModel_REPLACE"."GenericAnnotation_Audit" ("ValidFrom");
CREATE INDEX "Idx_GenericAnnotationAudit_ValidTo" ON "EngineeringModel_REPLACE"."GenericAnnotation_Audit" ("ValidTo");

CREATE TRIGGER GenericAnnotation_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."GenericAnnotation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER GenericAnnotation_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."GenericAnnotation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_EngineeringModelDataAnnotation_ValidFrom" ON "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ("ValidFrom");
CREATE INDEX "Idx_EngineeringModelDataAnnotation_ValidTo" ON "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Audit" (LIKE "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation");
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_EngineeringModelDataAnnotationAudit_ValidFrom" ON "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Audit" ("ValidFrom");
CREATE INDEX "Idx_EngineeringModelDataAnnotationAudit_ValidTo" ON "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Audit" ("ValidTo");

CREATE TRIGGER EngineeringModelDataAnnotation_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER EngineeringModelDataAnnotation_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataNote"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_EngineeringModelDataNote_ValidFrom" ON "EngineeringModel_REPLACE"."EngineeringModelDataNote" ("ValidFrom");
CREATE INDEX "Idx_EngineeringModelDataNote_ValidTo" ON "EngineeringModel_REPLACE"."EngineeringModelDataNote" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModelDataNote_Audit" (LIKE "EngineeringModel_REPLACE"."EngineeringModelDataNote");
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataNote_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_EngineeringModelDataNoteAudit_ValidFrom" ON "EngineeringModel_REPLACE"."EngineeringModelDataNote_Audit" ("ValidFrom");
CREATE INDEX "Idx_EngineeringModelDataNoteAudit_ValidTo" ON "EngineeringModel_REPLACE"."EngineeringModelDataNote_Audit" ("ValidTo");

CREATE TRIGGER EngineeringModelDataNote_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."EngineeringModelDataNote"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER EngineeringModelDataNote_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."EngineeringModelDataNote"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."ThingReference"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ThingReference_ValidFrom" ON "EngineeringModel_REPLACE"."ThingReference" ("ValidFrom");
CREATE INDEX "Idx_ThingReference_ValidTo" ON "EngineeringModel_REPLACE"."ThingReference" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ThingReference_Audit" (LIKE "EngineeringModel_REPLACE"."ThingReference");
ALTER TABLE "EngineeringModel_REPLACE"."ThingReference_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ThingReferenceAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ThingReference_Audit" ("ValidFrom");
CREATE INDEX "Idx_ThingReferenceAudit_ValidTo" ON "EngineeringModel_REPLACE"."ThingReference_Audit" ("ValidTo");

CREATE TRIGGER ThingReference_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ThingReference"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ThingReference_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ThingReference"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."ModellingThingReference"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ModellingThingReference_ValidFrom" ON "EngineeringModel_REPLACE"."ModellingThingReference" ("ValidFrom");
CREATE INDEX "Idx_ModellingThingReference_ValidTo" ON "EngineeringModel_REPLACE"."ModellingThingReference" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ModellingThingReference_Audit" (LIKE "EngineeringModel_REPLACE"."ModellingThingReference");
ALTER TABLE "EngineeringModel_REPLACE"."ModellingThingReference_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ModellingThingReferenceAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ModellingThingReference_Audit" ("ValidFrom");
CREATE INDEX "Idx_ModellingThingReferenceAudit_ValidTo" ON "EngineeringModel_REPLACE"."ModellingThingReference_Audit" ("ValidTo");

CREATE TRIGGER ModellingThingReference_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ModellingThingReference"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ModellingThingReference_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ModellingThingReference"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."DiscussionItem"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DiscussionItem_ValidFrom" ON "EngineeringModel_REPLACE"."DiscussionItem" ("ValidFrom");
CREATE INDEX "Idx_DiscussionItem_ValidTo" ON "EngineeringModel_REPLACE"."DiscussionItem" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."DiscussionItem_Audit" (LIKE "EngineeringModel_REPLACE"."DiscussionItem");
ALTER TABLE "EngineeringModel_REPLACE"."DiscussionItem_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DiscussionItemAudit_ValidFrom" ON "EngineeringModel_REPLACE"."DiscussionItem_Audit" ("ValidFrom");
CREATE INDEX "Idx_DiscussionItemAudit_ValidTo" ON "EngineeringModel_REPLACE"."DiscussionItem_Audit" ("ValidTo");

CREATE TRIGGER DiscussionItem_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."DiscussionItem"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DiscussionItem_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."DiscussionItem"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_EngineeringModelDataDiscussionItem_ValidFrom" ON "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem" ("ValidFrom");
CREATE INDEX "Idx_EngineeringModelDataDiscussionItem_ValidTo" ON "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Audit" (LIKE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem");
ALTER TABLE "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_EngineeringModelDataDiscussionItemAudit_ValidFrom" ON "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Audit" ("ValidFrom");
CREATE INDEX "Idx_EngineeringModelDataDiscussionItemAudit_ValidTo" ON "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Audit" ("ValidTo");

CREATE TRIGGER EngineeringModelDataDiscussionItem_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER EngineeringModelDataDiscussionItem_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ModellingAnnotationItem_ValidFrom" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("ValidFrom");
CREATE INDEX "Idx_ModellingAnnotationItem_ValidTo" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem_Audit" (LIKE "EngineeringModel_REPLACE"."ModellingAnnotationItem");
ALTER TABLE "EngineeringModel_REPLACE"."ModellingAnnotationItem_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ModellingAnnotationItemAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_Audit" ("ValidFrom");
CREATE INDEX "Idx_ModellingAnnotationItemAudit_ValidTo" ON "EngineeringModel_REPLACE"."ModellingAnnotationItem_Audit" ("ValidTo");

CREATE TRIGGER ModellingAnnotationItem_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ModellingAnnotationItem"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ModellingAnnotationItem_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ModellingAnnotationItem"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."ContractDeviation"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ContractDeviation_ValidFrom" ON "EngineeringModel_REPLACE"."ContractDeviation" ("ValidFrom");
CREATE INDEX "Idx_ContractDeviation_ValidTo" ON "EngineeringModel_REPLACE"."ContractDeviation" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ContractDeviation_Audit" (LIKE "EngineeringModel_REPLACE"."ContractDeviation");
ALTER TABLE "EngineeringModel_REPLACE"."ContractDeviation_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ContractDeviationAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ContractDeviation_Audit" ("ValidFrom");
CREATE INDEX "Idx_ContractDeviationAudit_ValidTo" ON "EngineeringModel_REPLACE"."ContractDeviation_Audit" ("ValidTo");

CREATE TRIGGER ContractDeviation_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ContractDeviation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ContractDeviation_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ContractDeviation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."RequestForWaiver"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RequestForWaiver_ValidFrom" ON "EngineeringModel_REPLACE"."RequestForWaiver" ("ValidFrom");
CREATE INDEX "Idx_RequestForWaiver_ValidTo" ON "EngineeringModel_REPLACE"."RequestForWaiver" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."RequestForWaiver_Audit" (LIKE "EngineeringModel_REPLACE"."RequestForWaiver");
ALTER TABLE "EngineeringModel_REPLACE"."RequestForWaiver_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RequestForWaiverAudit_ValidFrom" ON "EngineeringModel_REPLACE"."RequestForWaiver_Audit" ("ValidFrom");
CREATE INDEX "Idx_RequestForWaiverAudit_ValidTo" ON "EngineeringModel_REPLACE"."RequestForWaiver_Audit" ("ValidTo");

CREATE TRIGGER RequestForWaiver_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."RequestForWaiver"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RequestForWaiver_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."RequestForWaiver"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."Approval"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Approval_ValidFrom" ON "EngineeringModel_REPLACE"."Approval" ("ValidFrom");
CREATE INDEX "Idx_Approval_ValidTo" ON "EngineeringModel_REPLACE"."Approval" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Approval_Audit" (LIKE "EngineeringModel_REPLACE"."Approval");
ALTER TABLE "EngineeringModel_REPLACE"."Approval_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ApprovalAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Approval_Audit" ("ValidFrom");
CREATE INDEX "Idx_ApprovalAudit_ValidTo" ON "EngineeringModel_REPLACE"."Approval_Audit" ("ValidTo");

CREATE TRIGGER Approval_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Approval"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Approval_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Approval"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."RequestForDeviation"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RequestForDeviation_ValidFrom" ON "EngineeringModel_REPLACE"."RequestForDeviation" ("ValidFrom");
CREATE INDEX "Idx_RequestForDeviation_ValidTo" ON "EngineeringModel_REPLACE"."RequestForDeviation" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."RequestForDeviation_Audit" (LIKE "EngineeringModel_REPLACE"."RequestForDeviation");
ALTER TABLE "EngineeringModel_REPLACE"."RequestForDeviation_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RequestForDeviationAudit_ValidFrom" ON "EngineeringModel_REPLACE"."RequestForDeviation_Audit" ("ValidFrom");
CREATE INDEX "Idx_RequestForDeviationAudit_ValidTo" ON "EngineeringModel_REPLACE"."RequestForDeviation_Audit" ("ValidTo");

CREATE TRIGGER RequestForDeviation_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."RequestForDeviation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RequestForDeviation_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."RequestForDeviation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."ChangeRequest"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ChangeRequest_ValidFrom" ON "EngineeringModel_REPLACE"."ChangeRequest" ("ValidFrom");
CREATE INDEX "Idx_ChangeRequest_ValidTo" ON "EngineeringModel_REPLACE"."ChangeRequest" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ChangeRequest_Audit" (LIKE "EngineeringModel_REPLACE"."ChangeRequest");
ALTER TABLE "EngineeringModel_REPLACE"."ChangeRequest_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ChangeRequestAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ChangeRequest_Audit" ("ValidFrom");
CREATE INDEX "Idx_ChangeRequestAudit_ValidTo" ON "EngineeringModel_REPLACE"."ChangeRequest_Audit" ("ValidTo");

CREATE TRIGGER ChangeRequest_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ChangeRequest"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ChangeRequest_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ChangeRequest"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."ReviewItemDiscrepancy"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ReviewItemDiscrepancy_ValidFrom" ON "EngineeringModel_REPLACE"."ReviewItemDiscrepancy" ("ValidFrom");
CREATE INDEX "Idx_ReviewItemDiscrepancy_ValidTo" ON "EngineeringModel_REPLACE"."ReviewItemDiscrepancy" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_Audit" (LIKE "EngineeringModel_REPLACE"."ReviewItemDiscrepancy");
ALTER TABLE "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ReviewItemDiscrepancyAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_Audit" ("ValidFrom");
CREATE INDEX "Idx_ReviewItemDiscrepancyAudit_ValidTo" ON "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_Audit" ("ValidTo");

CREATE TRIGGER ReviewItemDiscrepancy_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ReviewItemDiscrepancy"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ReviewItemDiscrepancy_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ReviewItemDiscrepancy"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."Solution"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Solution_ValidFrom" ON "EngineeringModel_REPLACE"."Solution" ("ValidFrom");
CREATE INDEX "Idx_Solution_ValidTo" ON "EngineeringModel_REPLACE"."Solution" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."Solution_Audit" (LIKE "EngineeringModel_REPLACE"."Solution");
ALTER TABLE "EngineeringModel_REPLACE"."Solution_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_SolutionAudit_ValidFrom" ON "EngineeringModel_REPLACE"."Solution_Audit" ("ValidFrom");
CREATE INDEX "Idx_SolutionAudit_ValidTo" ON "EngineeringModel_REPLACE"."Solution_Audit" ("ValidTo");

CREATE TRIGGER Solution_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."Solution"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Solution_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."Solution"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."ActionItem"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ActionItem_ValidFrom" ON "EngineeringModel_REPLACE"."ActionItem" ("ValidFrom");
CREATE INDEX "Idx_ActionItem_ValidTo" ON "EngineeringModel_REPLACE"."ActionItem" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ActionItem_Audit" (LIKE "EngineeringModel_REPLACE"."ActionItem");
ALTER TABLE "EngineeringModel_REPLACE"."ActionItem_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ActionItemAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ActionItem_Audit" ("ValidFrom");
CREATE INDEX "Idx_ActionItemAudit_ValidTo" ON "EngineeringModel_REPLACE"."ActionItem_Audit" ("ValidTo");

CREATE TRIGGER ActionItem_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ActionItem"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ActionItem_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ActionItem"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."ChangeProposal"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ChangeProposal_ValidFrom" ON "EngineeringModel_REPLACE"."ChangeProposal" ("ValidFrom");
CREATE INDEX "Idx_ChangeProposal_ValidTo" ON "EngineeringModel_REPLACE"."ChangeProposal" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ChangeProposal_Audit" (LIKE "EngineeringModel_REPLACE"."ChangeProposal");
ALTER TABLE "EngineeringModel_REPLACE"."ChangeProposal_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ChangeProposalAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ChangeProposal_Audit" ("ValidFrom");
CREATE INDEX "Idx_ChangeProposalAudit_ValidTo" ON "EngineeringModel_REPLACE"."ChangeProposal_Audit" ("ValidTo");

CREATE TRIGGER ChangeProposal_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ChangeProposal"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ChangeProposal_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ChangeProposal"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "EngineeringModel_REPLACE"."ContractChangeNotice"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ContractChangeNotice_ValidFrom" ON "EngineeringModel_REPLACE"."ContractChangeNotice" ("ValidFrom");
CREATE INDEX "Idx_ContractChangeNotice_ValidTo" ON "EngineeringModel_REPLACE"."ContractChangeNotice" ("ValidTo");

CREATE TABLE "EngineeringModel_REPLACE"."ContractChangeNotice_Audit" (LIKE "EngineeringModel_REPLACE"."ContractChangeNotice");
ALTER TABLE "EngineeringModel_REPLACE"."ContractChangeNotice_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ContractChangeNoticeAudit_ValidFrom" ON "EngineeringModel_REPLACE"."ContractChangeNotice_Audit" ("ValidFrom");
CREATE INDEX "Idx_ContractChangeNoticeAudit_ValidTo" ON "EngineeringModel_REPLACE"."ContractChangeNotice_Audit" ("ValidTo");

CREATE TRIGGER ContractChangeNotice_audit_prepare
  BEFORE UPDATE ON "EngineeringModel_REPLACE"."ContractChangeNotice"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ContractChangeNotice_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "EngineeringModel_REPLACE"."ContractChangeNotice"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Thing"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Thing_ValidFrom" ON "Iteration_REPLACE"."Thing" ("ValidFrom");
CREATE INDEX "Idx_Thing_ValidTo" ON "Iteration_REPLACE"."Thing" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Thing_Audit" (LIKE "Iteration_REPLACE"."Thing");
ALTER TABLE "Iteration_REPLACE"."Thing_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ThingAudit_ValidFrom" ON "Iteration_REPLACE"."Thing_Audit" ("ValidFrom");
CREATE INDEX "Idx_ThingAudit_ValidTo" ON "Iteration_REPLACE"."Thing_Audit" ("ValidTo");

CREATE TRIGGER Thing_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Thing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Thing_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Thing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."DefinedThing"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DefinedThing_ValidFrom" ON "Iteration_REPLACE"."DefinedThing" ("ValidFrom");
CREATE INDEX "Idx_DefinedThing_ValidTo" ON "Iteration_REPLACE"."DefinedThing" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."DefinedThing_Audit" (LIKE "Iteration_REPLACE"."DefinedThing");
ALTER TABLE "Iteration_REPLACE"."DefinedThing_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DefinedThingAudit_ValidFrom" ON "Iteration_REPLACE"."DefinedThing_Audit" ("ValidFrom");
CREATE INDEX "Idx_DefinedThingAudit_ValidTo" ON "Iteration_REPLACE"."DefinedThing_Audit" ("ValidTo");

CREATE TRIGGER DefinedThing_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."DefinedThing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DefinedThing_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."DefinedThing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Option"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Option_ValidFrom" ON "Iteration_REPLACE"."Option" ("ValidFrom");
CREATE INDEX "Idx_Option_ValidTo" ON "Iteration_REPLACE"."Option" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Option_Audit" (LIKE "Iteration_REPLACE"."Option");
ALTER TABLE "Iteration_REPLACE"."Option_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_OptionAudit_ValidFrom" ON "Iteration_REPLACE"."Option_Audit" ("ValidFrom");
CREATE INDEX "Idx_OptionAudit_ValidTo" ON "Iteration_REPLACE"."Option_Audit" ("ValidTo");

CREATE TRIGGER Option_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Option"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Option_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Option"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Alias"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Alias_ValidFrom" ON "Iteration_REPLACE"."Alias" ("ValidFrom");
CREATE INDEX "Idx_Alias_ValidTo" ON "Iteration_REPLACE"."Alias" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Alias_Audit" (LIKE "Iteration_REPLACE"."Alias");
ALTER TABLE "Iteration_REPLACE"."Alias_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_AliasAudit_ValidFrom" ON "Iteration_REPLACE"."Alias_Audit" ("ValidFrom");
CREATE INDEX "Idx_AliasAudit_ValidTo" ON "Iteration_REPLACE"."Alias_Audit" ("ValidTo");

CREATE TRIGGER Alias_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Alias"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Alias_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Alias"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Definition"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Definition_ValidFrom" ON "Iteration_REPLACE"."Definition" ("ValidFrom");
CREATE INDEX "Idx_Definition_ValidTo" ON "Iteration_REPLACE"."Definition" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Definition_Audit" (LIKE "Iteration_REPLACE"."Definition");
ALTER TABLE "Iteration_REPLACE"."Definition_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DefinitionAudit_ValidFrom" ON "Iteration_REPLACE"."Definition_Audit" ("ValidFrom");
CREATE INDEX "Idx_DefinitionAudit_ValidTo" ON "Iteration_REPLACE"."Definition_Audit" ("ValidTo");

CREATE TRIGGER Definition_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Definition"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Definition_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Definition"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Citation"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Citation_ValidFrom" ON "Iteration_REPLACE"."Citation" ("ValidFrom");
CREATE INDEX "Idx_Citation_ValidTo" ON "Iteration_REPLACE"."Citation" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Citation_Audit" (LIKE "Iteration_REPLACE"."Citation");
ALTER TABLE "Iteration_REPLACE"."Citation_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_CitationAudit_ValidFrom" ON "Iteration_REPLACE"."Citation_Audit" ("ValidFrom");
CREATE INDEX "Idx_CitationAudit_ValidTo" ON "Iteration_REPLACE"."Citation_Audit" ("ValidTo");

CREATE TRIGGER Citation_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Citation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Citation_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Citation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."HyperLink"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_HyperLink_ValidFrom" ON "Iteration_REPLACE"."HyperLink" ("ValidFrom");
CREATE INDEX "Idx_HyperLink_ValidTo" ON "Iteration_REPLACE"."HyperLink" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."HyperLink_Audit" (LIKE "Iteration_REPLACE"."HyperLink");
ALTER TABLE "Iteration_REPLACE"."HyperLink_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_HyperLinkAudit_ValidFrom" ON "Iteration_REPLACE"."HyperLink_Audit" ("ValidFrom");
CREATE INDEX "Idx_HyperLinkAudit_ValidTo" ON "Iteration_REPLACE"."HyperLink_Audit" ("ValidTo");

CREATE TRIGGER HyperLink_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."HyperLink"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER HyperLink_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."HyperLink"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."NestedElement"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_NestedElement_ValidFrom" ON "Iteration_REPLACE"."NestedElement" ("ValidFrom");
CREATE INDEX "Idx_NestedElement_ValidTo" ON "Iteration_REPLACE"."NestedElement" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."NestedElement_Audit" (LIKE "Iteration_REPLACE"."NestedElement");
ALTER TABLE "Iteration_REPLACE"."NestedElement_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_NestedElementAudit_ValidFrom" ON "Iteration_REPLACE"."NestedElement_Audit" ("ValidFrom");
CREATE INDEX "Idx_NestedElementAudit_ValidTo" ON "Iteration_REPLACE"."NestedElement_Audit" ("ValidTo");

CREATE TRIGGER NestedElement_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."NestedElement"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER NestedElement_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."NestedElement"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."NestedParameter"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_NestedParameter_ValidFrom" ON "Iteration_REPLACE"."NestedParameter" ("ValidFrom");
CREATE INDEX "Idx_NestedParameter_ValidTo" ON "Iteration_REPLACE"."NestedParameter" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."NestedParameter_Audit" (LIKE "Iteration_REPLACE"."NestedParameter");
ALTER TABLE "Iteration_REPLACE"."NestedParameter_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_NestedParameterAudit_ValidFrom" ON "Iteration_REPLACE"."NestedParameter_Audit" ("ValidFrom");
CREATE INDEX "Idx_NestedParameterAudit_ValidTo" ON "Iteration_REPLACE"."NestedParameter_Audit" ("ValidTo");

CREATE TRIGGER NestedParameter_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."NestedParameter"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER NestedParameter_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."NestedParameter"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Publication"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Publication_ValidFrom" ON "Iteration_REPLACE"."Publication" ("ValidFrom");
CREATE INDEX "Idx_Publication_ValidTo" ON "Iteration_REPLACE"."Publication" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Publication_Audit" (LIKE "Iteration_REPLACE"."Publication");
ALTER TABLE "Iteration_REPLACE"."Publication_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_PublicationAudit_ValidFrom" ON "Iteration_REPLACE"."Publication_Audit" ("ValidFrom");
CREATE INDEX "Idx_PublicationAudit_ValidTo" ON "Iteration_REPLACE"."Publication_Audit" ("ValidTo");

CREATE TRIGGER Publication_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Publication"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Publication_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Publication"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_PossibleFiniteStateList_ValidFrom" ON "Iteration_REPLACE"."PossibleFiniteStateList" ("ValidFrom");
CREATE INDEX "Idx_PossibleFiniteStateList_ValidTo" ON "Iteration_REPLACE"."PossibleFiniteStateList" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."PossibleFiniteStateList_Audit" (LIKE "Iteration_REPLACE"."PossibleFiniteStateList");
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteStateList_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_PossibleFiniteStateListAudit_ValidFrom" ON "Iteration_REPLACE"."PossibleFiniteStateList_Audit" ("ValidFrom");
CREATE INDEX "Idx_PossibleFiniteStateListAudit_ValidTo" ON "Iteration_REPLACE"."PossibleFiniteStateList_Audit" ("ValidTo");

CREATE TRIGGER PossibleFiniteStateList_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."PossibleFiniteStateList"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER PossibleFiniteStateList_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."PossibleFiniteStateList"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteState"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_PossibleFiniteState_ValidFrom" ON "Iteration_REPLACE"."PossibleFiniteState" ("ValidFrom");
CREATE INDEX "Idx_PossibleFiniteState_ValidTo" ON "Iteration_REPLACE"."PossibleFiniteState" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."PossibleFiniteState_Audit" (LIKE "Iteration_REPLACE"."PossibleFiniteState");
ALTER TABLE "Iteration_REPLACE"."PossibleFiniteState_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_PossibleFiniteStateAudit_ValidFrom" ON "Iteration_REPLACE"."PossibleFiniteState_Audit" ("ValidFrom");
CREATE INDEX "Idx_PossibleFiniteStateAudit_ValidTo" ON "Iteration_REPLACE"."PossibleFiniteState_Audit" ("ValidTo");

CREATE TRIGGER PossibleFiniteState_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."PossibleFiniteState"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER PossibleFiniteState_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."PossibleFiniteState"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ElementBase"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ElementBase_ValidFrom" ON "Iteration_REPLACE"."ElementBase" ("ValidFrom");
CREATE INDEX "Idx_ElementBase_ValidTo" ON "Iteration_REPLACE"."ElementBase" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ElementBase_Audit" (LIKE "Iteration_REPLACE"."ElementBase");
ALTER TABLE "Iteration_REPLACE"."ElementBase_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ElementBaseAudit_ValidFrom" ON "Iteration_REPLACE"."ElementBase_Audit" ("ValidFrom");
CREATE INDEX "Idx_ElementBaseAudit_ValidTo" ON "Iteration_REPLACE"."ElementBase_Audit" ("ValidTo");

CREATE TRIGGER ElementBase_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ElementBase"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ElementBase_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ElementBase"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ElementDefinition"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ElementDefinition_ValidFrom" ON "Iteration_REPLACE"."ElementDefinition" ("ValidFrom");
CREATE INDEX "Idx_ElementDefinition_ValidTo" ON "Iteration_REPLACE"."ElementDefinition" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ElementDefinition_Audit" (LIKE "Iteration_REPLACE"."ElementDefinition");
ALTER TABLE "Iteration_REPLACE"."ElementDefinition_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ElementDefinitionAudit_ValidFrom" ON "Iteration_REPLACE"."ElementDefinition_Audit" ("ValidFrom");
CREATE INDEX "Idx_ElementDefinitionAudit_ValidTo" ON "Iteration_REPLACE"."ElementDefinition_Audit" ("ValidTo");

CREATE TRIGGER ElementDefinition_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ElementDefinition"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ElementDefinition_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ElementDefinition"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ElementUsage"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ElementUsage_ValidFrom" ON "Iteration_REPLACE"."ElementUsage" ("ValidFrom");
CREATE INDEX "Idx_ElementUsage_ValidTo" ON "Iteration_REPLACE"."ElementUsage" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ElementUsage_Audit" (LIKE "Iteration_REPLACE"."ElementUsage");
ALTER TABLE "Iteration_REPLACE"."ElementUsage_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ElementUsageAudit_ValidFrom" ON "Iteration_REPLACE"."ElementUsage_Audit" ("ValidFrom");
CREATE INDEX "Idx_ElementUsageAudit_ValidTo" ON "Iteration_REPLACE"."ElementUsage_Audit" ("ValidTo");

CREATE TRIGGER ElementUsage_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ElementUsage"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ElementUsage_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ElementUsage"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParameterBase"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParameterBase_ValidFrom" ON "Iteration_REPLACE"."ParameterBase" ("ValidFrom");
CREATE INDEX "Idx_ParameterBase_ValidTo" ON "Iteration_REPLACE"."ParameterBase" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParameterBase_Audit" (LIKE "Iteration_REPLACE"."ParameterBase");
ALTER TABLE "Iteration_REPLACE"."ParameterBase_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterBaseAudit_ValidFrom" ON "Iteration_REPLACE"."ParameterBase_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterBaseAudit_ValidTo" ON "Iteration_REPLACE"."ParameterBase_Audit" ("ValidTo");

CREATE TRIGGER ParameterBase_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParameterBase"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParameterBase_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParameterBase"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParameterOrOverrideBase"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParameterOrOverrideBase_ValidFrom" ON "Iteration_REPLACE"."ParameterOrOverrideBase" ("ValidFrom");
CREATE INDEX "Idx_ParameterOrOverrideBase_ValidTo" ON "Iteration_REPLACE"."ParameterOrOverrideBase" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParameterOrOverrideBase_Audit" (LIKE "Iteration_REPLACE"."ParameterOrOverrideBase");
ALTER TABLE "Iteration_REPLACE"."ParameterOrOverrideBase_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterOrOverrideBaseAudit_ValidFrom" ON "Iteration_REPLACE"."ParameterOrOverrideBase_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterOrOverrideBaseAudit_ValidTo" ON "Iteration_REPLACE"."ParameterOrOverrideBase_Audit" ("ValidTo");

CREATE TRIGGER ParameterOrOverrideBase_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParameterOrOverrideBase"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParameterOrOverrideBase_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParameterOrOverrideBase"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParameterOverride"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParameterOverride_ValidFrom" ON "Iteration_REPLACE"."ParameterOverride" ("ValidFrom");
CREATE INDEX "Idx_ParameterOverride_ValidTo" ON "Iteration_REPLACE"."ParameterOverride" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParameterOverride_Audit" (LIKE "Iteration_REPLACE"."ParameterOverride");
ALTER TABLE "Iteration_REPLACE"."ParameterOverride_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterOverrideAudit_ValidFrom" ON "Iteration_REPLACE"."ParameterOverride_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterOverrideAudit_ValidTo" ON "Iteration_REPLACE"."ParameterOverride_Audit" ("ValidTo");

CREATE TRIGGER ParameterOverride_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParameterOverride"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParameterOverride_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParameterOverride"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParameterSubscription"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParameterSubscription_ValidFrom" ON "Iteration_REPLACE"."ParameterSubscription" ("ValidFrom");
CREATE INDEX "Idx_ParameterSubscription_ValidTo" ON "Iteration_REPLACE"."ParameterSubscription" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParameterSubscription_Audit" (LIKE "Iteration_REPLACE"."ParameterSubscription");
ALTER TABLE "Iteration_REPLACE"."ParameterSubscription_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterSubscriptionAudit_ValidFrom" ON "Iteration_REPLACE"."ParameterSubscription_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterSubscriptionAudit_ValidTo" ON "Iteration_REPLACE"."ParameterSubscription_Audit" ("ValidTo");

CREATE TRIGGER ParameterSubscription_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParameterSubscription"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParameterSubscription_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParameterSubscription"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParameterSubscriptionValueSet_ValidFrom" ON "Iteration_REPLACE"."ParameterSubscriptionValueSet" ("ValidFrom");
CREATE INDEX "Idx_ParameterSubscriptionValueSet_ValidTo" ON "Iteration_REPLACE"."ParameterSubscriptionValueSet" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet_Audit" (LIKE "Iteration_REPLACE"."ParameterSubscriptionValueSet");
ALTER TABLE "Iteration_REPLACE"."ParameterSubscriptionValueSet_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterSubscriptionValueSetAudit_ValidFrom" ON "Iteration_REPLACE"."ParameterSubscriptionValueSet_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterSubscriptionValueSetAudit_ValidTo" ON "Iteration_REPLACE"."ParameterSubscriptionValueSet_Audit" ("ValidTo");

CREATE TRIGGER ParameterSubscriptionValueSet_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParameterSubscriptionValueSet"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParameterSubscriptionValueSet_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParameterSubscriptionValueSet"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParameterValueSetBase"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParameterValueSetBase_ValidFrom" ON "Iteration_REPLACE"."ParameterValueSetBase" ("ValidFrom");
CREATE INDEX "Idx_ParameterValueSetBase_ValidTo" ON "Iteration_REPLACE"."ParameterValueSetBase" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParameterValueSetBase_Audit" (LIKE "Iteration_REPLACE"."ParameterValueSetBase");
ALTER TABLE "Iteration_REPLACE"."ParameterValueSetBase_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterValueSetBaseAudit_ValidFrom" ON "Iteration_REPLACE"."ParameterValueSetBase_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterValueSetBaseAudit_ValidTo" ON "Iteration_REPLACE"."ParameterValueSetBase_Audit" ("ValidTo");

CREATE TRIGGER ParameterValueSetBase_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParameterValueSetBase"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParameterValueSetBase_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParameterValueSetBase"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParameterOverrideValueSet"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParameterOverrideValueSet_ValidFrom" ON "Iteration_REPLACE"."ParameterOverrideValueSet" ("ValidFrom");
CREATE INDEX "Idx_ParameterOverrideValueSet_ValidTo" ON "Iteration_REPLACE"."ParameterOverrideValueSet" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParameterOverrideValueSet_Audit" (LIKE "Iteration_REPLACE"."ParameterOverrideValueSet");
ALTER TABLE "Iteration_REPLACE"."ParameterOverrideValueSet_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterOverrideValueSetAudit_ValidFrom" ON "Iteration_REPLACE"."ParameterOverrideValueSet_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterOverrideValueSetAudit_ValidTo" ON "Iteration_REPLACE"."ParameterOverrideValueSet_Audit" ("ValidTo");

CREATE TRIGGER ParameterOverrideValueSet_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParameterOverrideValueSet"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParameterOverrideValueSet_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParameterOverrideValueSet"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Parameter"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Parameter_ValidFrom" ON "Iteration_REPLACE"."Parameter" ("ValidFrom");
CREATE INDEX "Idx_Parameter_ValidTo" ON "Iteration_REPLACE"."Parameter" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Parameter_Audit" (LIKE "Iteration_REPLACE"."Parameter");
ALTER TABLE "Iteration_REPLACE"."Parameter_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterAudit_ValidFrom" ON "Iteration_REPLACE"."Parameter_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterAudit_ValidTo" ON "Iteration_REPLACE"."Parameter_Audit" ("ValidTo");

CREATE TRIGGER Parameter_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Parameter"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Parameter_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Parameter"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParameterValueSet"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParameterValueSet_ValidFrom" ON "Iteration_REPLACE"."ParameterValueSet" ("ValidFrom");
CREATE INDEX "Idx_ParameterValueSet_ValidTo" ON "Iteration_REPLACE"."ParameterValueSet" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParameterValueSet_Audit" (LIKE "Iteration_REPLACE"."ParameterValueSet");
ALTER TABLE "Iteration_REPLACE"."ParameterValueSet_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterValueSetAudit_ValidFrom" ON "Iteration_REPLACE"."ParameterValueSet_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterValueSetAudit_ValidTo" ON "Iteration_REPLACE"."ParameterValueSet_Audit" ("ValidTo");

CREATE TRIGGER ParameterValueSet_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParameterValueSet"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParameterValueSet_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParameterValueSet"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParameterGroup"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParameterGroup_ValidFrom" ON "Iteration_REPLACE"."ParameterGroup" ("ValidFrom");
CREATE INDEX "Idx_ParameterGroup_ValidTo" ON "Iteration_REPLACE"."ParameterGroup" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParameterGroup_Audit" (LIKE "Iteration_REPLACE"."ParameterGroup");
ALTER TABLE "Iteration_REPLACE"."ParameterGroup_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterGroupAudit_ValidFrom" ON "Iteration_REPLACE"."ParameterGroup_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterGroupAudit_ValidTo" ON "Iteration_REPLACE"."ParameterGroup_Audit" ("ValidTo");

CREATE TRIGGER ParameterGroup_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParameterGroup"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParameterGroup_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParameterGroup"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Relationship"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Relationship_ValidFrom" ON "Iteration_REPLACE"."Relationship" ("ValidFrom");
CREATE INDEX "Idx_Relationship_ValidTo" ON "Iteration_REPLACE"."Relationship" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Relationship_Audit" (LIKE "Iteration_REPLACE"."Relationship");
ALTER TABLE "Iteration_REPLACE"."Relationship_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RelationshipAudit_ValidFrom" ON "Iteration_REPLACE"."Relationship_Audit" ("ValidFrom");
CREATE INDEX "Idx_RelationshipAudit_ValidTo" ON "Iteration_REPLACE"."Relationship_Audit" ("ValidTo");

CREATE TRIGGER Relationship_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Relationship"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Relationship_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Relationship"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."MultiRelationship"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_MultiRelationship_ValidFrom" ON "Iteration_REPLACE"."MultiRelationship" ("ValidFrom");
CREATE INDEX "Idx_MultiRelationship_ValidTo" ON "Iteration_REPLACE"."MultiRelationship" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."MultiRelationship_Audit" (LIKE "Iteration_REPLACE"."MultiRelationship");
ALTER TABLE "Iteration_REPLACE"."MultiRelationship_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_MultiRelationshipAudit_ValidFrom" ON "Iteration_REPLACE"."MultiRelationship_Audit" ("ValidFrom");
CREATE INDEX "Idx_MultiRelationshipAudit_ValidTo" ON "Iteration_REPLACE"."MultiRelationship_Audit" ("ValidTo");

CREATE TRIGGER MultiRelationship_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."MultiRelationship"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER MultiRelationship_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."MultiRelationship"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParameterValue"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParameterValue_ValidFrom" ON "Iteration_REPLACE"."ParameterValue" ("ValidFrom");
CREATE INDEX "Idx_ParameterValue_ValidTo" ON "Iteration_REPLACE"."ParameterValue" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParameterValue_Audit" (LIKE "Iteration_REPLACE"."ParameterValue");
ALTER TABLE "Iteration_REPLACE"."ParameterValue_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParameterValueAudit_ValidFrom" ON "Iteration_REPLACE"."ParameterValue_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParameterValueAudit_ValidTo" ON "Iteration_REPLACE"."ParameterValue_Audit" ("ValidTo");

CREATE TRIGGER ParameterValue_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParameterValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParameterValue_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParameterValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."RelationshipParameterValue"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RelationshipParameterValue_ValidFrom" ON "Iteration_REPLACE"."RelationshipParameterValue" ("ValidFrom");
CREATE INDEX "Idx_RelationshipParameterValue_ValidTo" ON "Iteration_REPLACE"."RelationshipParameterValue" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RelationshipParameterValue_Audit" (LIKE "Iteration_REPLACE"."RelationshipParameterValue");
ALTER TABLE "Iteration_REPLACE"."RelationshipParameterValue_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RelationshipParameterValueAudit_ValidFrom" ON "Iteration_REPLACE"."RelationshipParameterValue_Audit" ("ValidFrom");
CREATE INDEX "Idx_RelationshipParameterValueAudit_ValidTo" ON "Iteration_REPLACE"."RelationshipParameterValue_Audit" ("ValidTo");

CREATE TRIGGER RelationshipParameterValue_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RelationshipParameterValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RelationshipParameterValue_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RelationshipParameterValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."BinaryRelationship"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_BinaryRelationship_ValidFrom" ON "Iteration_REPLACE"."BinaryRelationship" ("ValidFrom");
CREATE INDEX "Idx_BinaryRelationship_ValidTo" ON "Iteration_REPLACE"."BinaryRelationship" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."BinaryRelationship_Audit" (LIKE "Iteration_REPLACE"."BinaryRelationship");
ALTER TABLE "Iteration_REPLACE"."BinaryRelationship_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_BinaryRelationshipAudit_ValidFrom" ON "Iteration_REPLACE"."BinaryRelationship_Audit" ("ValidFrom");
CREATE INDEX "Idx_BinaryRelationshipAudit_ValidTo" ON "Iteration_REPLACE"."BinaryRelationship_Audit" ("ValidTo");

CREATE TRIGGER BinaryRelationship_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."BinaryRelationship"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER BinaryRelationship_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."BinaryRelationship"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ExternalIdentifierMap"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ExternalIdentifierMap_ValidFrom" ON "Iteration_REPLACE"."ExternalIdentifierMap" ("ValidFrom");
CREATE INDEX "Idx_ExternalIdentifierMap_ValidTo" ON "Iteration_REPLACE"."ExternalIdentifierMap" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ExternalIdentifierMap_Audit" (LIKE "Iteration_REPLACE"."ExternalIdentifierMap");
ALTER TABLE "Iteration_REPLACE"."ExternalIdentifierMap_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ExternalIdentifierMapAudit_ValidFrom" ON "Iteration_REPLACE"."ExternalIdentifierMap_Audit" ("ValidFrom");
CREATE INDEX "Idx_ExternalIdentifierMapAudit_ValidTo" ON "Iteration_REPLACE"."ExternalIdentifierMap_Audit" ("ValidTo");

CREATE TRIGGER ExternalIdentifierMap_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ExternalIdentifierMap"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ExternalIdentifierMap_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ExternalIdentifierMap"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."IdCorrespondence"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_IdCorrespondence_ValidFrom" ON "Iteration_REPLACE"."IdCorrespondence" ("ValidFrom");
CREATE INDEX "Idx_IdCorrespondence_ValidTo" ON "Iteration_REPLACE"."IdCorrespondence" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."IdCorrespondence_Audit" (LIKE "Iteration_REPLACE"."IdCorrespondence");
ALTER TABLE "Iteration_REPLACE"."IdCorrespondence_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_IdCorrespondenceAudit_ValidFrom" ON "Iteration_REPLACE"."IdCorrespondence_Audit" ("ValidFrom");
CREATE INDEX "Idx_IdCorrespondenceAudit_ValidTo" ON "Iteration_REPLACE"."IdCorrespondence_Audit" ("ValidTo");

CREATE TRIGGER IdCorrespondence_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."IdCorrespondence"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER IdCorrespondence_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."IdCorrespondence"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."RequirementsContainer"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RequirementsContainer_ValidFrom" ON "Iteration_REPLACE"."RequirementsContainer" ("ValidFrom");
CREATE INDEX "Idx_RequirementsContainer_ValidTo" ON "Iteration_REPLACE"."RequirementsContainer" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RequirementsContainer_Audit" (LIKE "Iteration_REPLACE"."RequirementsContainer");
ALTER TABLE "Iteration_REPLACE"."RequirementsContainer_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RequirementsContainerAudit_ValidFrom" ON "Iteration_REPLACE"."RequirementsContainer_Audit" ("ValidFrom");
CREATE INDEX "Idx_RequirementsContainerAudit_ValidTo" ON "Iteration_REPLACE"."RequirementsContainer_Audit" ("ValidTo");

CREATE TRIGGER RequirementsContainer_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RequirementsContainer"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RequirementsContainer_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RequirementsContainer"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."RequirementsSpecification"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RequirementsSpecification_ValidFrom" ON "Iteration_REPLACE"."RequirementsSpecification" ("ValidFrom");
CREATE INDEX "Idx_RequirementsSpecification_ValidTo" ON "Iteration_REPLACE"."RequirementsSpecification" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RequirementsSpecification_Audit" (LIKE "Iteration_REPLACE"."RequirementsSpecification");
ALTER TABLE "Iteration_REPLACE"."RequirementsSpecification_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RequirementsSpecificationAudit_ValidFrom" ON "Iteration_REPLACE"."RequirementsSpecification_Audit" ("ValidFrom");
CREATE INDEX "Idx_RequirementsSpecificationAudit_ValidTo" ON "Iteration_REPLACE"."RequirementsSpecification_Audit" ("ValidTo");

CREATE TRIGGER RequirementsSpecification_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RequirementsSpecification"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RequirementsSpecification_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RequirementsSpecification"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."RequirementsGroup"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RequirementsGroup_ValidFrom" ON "Iteration_REPLACE"."RequirementsGroup" ("ValidFrom");
CREATE INDEX "Idx_RequirementsGroup_ValidTo" ON "Iteration_REPLACE"."RequirementsGroup" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RequirementsGroup_Audit" (LIKE "Iteration_REPLACE"."RequirementsGroup");
ALTER TABLE "Iteration_REPLACE"."RequirementsGroup_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RequirementsGroupAudit_ValidFrom" ON "Iteration_REPLACE"."RequirementsGroup_Audit" ("ValidFrom");
CREATE INDEX "Idx_RequirementsGroupAudit_ValidTo" ON "Iteration_REPLACE"."RequirementsGroup_Audit" ("ValidTo");

CREATE TRIGGER RequirementsGroup_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RequirementsGroup"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RequirementsGroup_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RequirementsGroup"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."RequirementsContainerParameterValue"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RequirementsContainerParameterValue_ValidFrom" ON "Iteration_REPLACE"."RequirementsContainerParameterValue" ("ValidFrom");
CREATE INDEX "Idx_RequirementsContainerParameterValue_ValidTo" ON "Iteration_REPLACE"."RequirementsContainerParameterValue" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RequirementsContainerParameterValue_Audit" (LIKE "Iteration_REPLACE"."RequirementsContainerParameterValue");
ALTER TABLE "Iteration_REPLACE"."RequirementsContainerParameterValue_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RequirementsContainerParameterValueAudit_ValidFrom" ON "Iteration_REPLACE"."RequirementsContainerParameterValue_Audit" ("ValidFrom");
CREATE INDEX "Idx_RequirementsContainerParameterValueAudit_ValidTo" ON "Iteration_REPLACE"."RequirementsContainerParameterValue_Audit" ("ValidTo");

CREATE TRIGGER RequirementsContainerParameterValue_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RequirementsContainerParameterValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RequirementsContainerParameterValue_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RequirementsContainerParameterValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."SimpleParameterizableThing"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_SimpleParameterizableThing_ValidFrom" ON "Iteration_REPLACE"."SimpleParameterizableThing" ("ValidFrom");
CREATE INDEX "Idx_SimpleParameterizableThing_ValidTo" ON "Iteration_REPLACE"."SimpleParameterizableThing" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."SimpleParameterizableThing_Audit" (LIKE "Iteration_REPLACE"."SimpleParameterizableThing");
ALTER TABLE "Iteration_REPLACE"."SimpleParameterizableThing_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_SimpleParameterizableThingAudit_ValidFrom" ON "Iteration_REPLACE"."SimpleParameterizableThing_Audit" ("ValidFrom");
CREATE INDEX "Idx_SimpleParameterizableThingAudit_ValidTo" ON "Iteration_REPLACE"."SimpleParameterizableThing_Audit" ("ValidTo");

CREATE TRIGGER SimpleParameterizableThing_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."SimpleParameterizableThing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER SimpleParameterizableThing_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."SimpleParameterizableThing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Requirement"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Requirement_ValidFrom" ON "Iteration_REPLACE"."Requirement" ("ValidFrom");
CREATE INDEX "Idx_Requirement_ValidTo" ON "Iteration_REPLACE"."Requirement" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Requirement_Audit" (LIKE "Iteration_REPLACE"."Requirement");
ALTER TABLE "Iteration_REPLACE"."Requirement_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RequirementAudit_ValidFrom" ON "Iteration_REPLACE"."Requirement_Audit" ("ValidFrom");
CREATE INDEX "Idx_RequirementAudit_ValidTo" ON "Iteration_REPLACE"."Requirement_Audit" ("ValidTo");

CREATE TRIGGER Requirement_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Requirement"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Requirement_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Requirement"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."SimpleParameterValue"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_SimpleParameterValue_ValidFrom" ON "Iteration_REPLACE"."SimpleParameterValue" ("ValidFrom");
CREATE INDEX "Idx_SimpleParameterValue_ValidTo" ON "Iteration_REPLACE"."SimpleParameterValue" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."SimpleParameterValue_Audit" (LIKE "Iteration_REPLACE"."SimpleParameterValue");
ALTER TABLE "Iteration_REPLACE"."SimpleParameterValue_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_SimpleParameterValueAudit_ValidFrom" ON "Iteration_REPLACE"."SimpleParameterValue_Audit" ("ValidFrom");
CREATE INDEX "Idx_SimpleParameterValueAudit_ValidTo" ON "Iteration_REPLACE"."SimpleParameterValue_Audit" ("ValidTo");

CREATE TRIGGER SimpleParameterValue_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."SimpleParameterValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER SimpleParameterValue_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."SimpleParameterValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ParametricConstraint"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ParametricConstraint_ValidFrom" ON "Iteration_REPLACE"."ParametricConstraint" ("ValidFrom");
CREATE INDEX "Idx_ParametricConstraint_ValidTo" ON "Iteration_REPLACE"."ParametricConstraint" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ParametricConstraint_Audit" (LIKE "Iteration_REPLACE"."ParametricConstraint");
ALTER TABLE "Iteration_REPLACE"."ParametricConstraint_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ParametricConstraintAudit_ValidFrom" ON "Iteration_REPLACE"."ParametricConstraint_Audit" ("ValidFrom");
CREATE INDEX "Idx_ParametricConstraintAudit_ValidTo" ON "Iteration_REPLACE"."ParametricConstraint_Audit" ("ValidTo");

CREATE TRIGGER ParametricConstraint_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ParametricConstraint"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ParametricConstraint_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ParametricConstraint"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."BooleanExpression"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_BooleanExpression_ValidFrom" ON "Iteration_REPLACE"."BooleanExpression" ("ValidFrom");
CREATE INDEX "Idx_BooleanExpression_ValidTo" ON "Iteration_REPLACE"."BooleanExpression" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."BooleanExpression_Audit" (LIKE "Iteration_REPLACE"."BooleanExpression");
ALTER TABLE "Iteration_REPLACE"."BooleanExpression_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_BooleanExpressionAudit_ValidFrom" ON "Iteration_REPLACE"."BooleanExpression_Audit" ("ValidFrom");
CREATE INDEX "Idx_BooleanExpressionAudit_ValidTo" ON "Iteration_REPLACE"."BooleanExpression_Audit" ("ValidTo");

CREATE TRIGGER BooleanExpression_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."BooleanExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER BooleanExpression_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."BooleanExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."OrExpression"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_OrExpression_ValidFrom" ON "Iteration_REPLACE"."OrExpression" ("ValidFrom");
CREATE INDEX "Idx_OrExpression_ValidTo" ON "Iteration_REPLACE"."OrExpression" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."OrExpression_Audit" (LIKE "Iteration_REPLACE"."OrExpression");
ALTER TABLE "Iteration_REPLACE"."OrExpression_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_OrExpressionAudit_ValidFrom" ON "Iteration_REPLACE"."OrExpression_Audit" ("ValidFrom");
CREATE INDEX "Idx_OrExpressionAudit_ValidTo" ON "Iteration_REPLACE"."OrExpression_Audit" ("ValidTo");

CREATE TRIGGER OrExpression_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."OrExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER OrExpression_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."OrExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."NotExpression"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_NotExpression_ValidFrom" ON "Iteration_REPLACE"."NotExpression" ("ValidFrom");
CREATE INDEX "Idx_NotExpression_ValidTo" ON "Iteration_REPLACE"."NotExpression" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."NotExpression_Audit" (LIKE "Iteration_REPLACE"."NotExpression");
ALTER TABLE "Iteration_REPLACE"."NotExpression_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_NotExpressionAudit_ValidFrom" ON "Iteration_REPLACE"."NotExpression_Audit" ("ValidFrom");
CREATE INDEX "Idx_NotExpressionAudit_ValidTo" ON "Iteration_REPLACE"."NotExpression_Audit" ("ValidTo");

CREATE TRIGGER NotExpression_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."NotExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER NotExpression_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."NotExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."AndExpression"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_AndExpression_ValidFrom" ON "Iteration_REPLACE"."AndExpression" ("ValidFrom");
CREATE INDEX "Idx_AndExpression_ValidTo" ON "Iteration_REPLACE"."AndExpression" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."AndExpression_Audit" (LIKE "Iteration_REPLACE"."AndExpression");
ALTER TABLE "Iteration_REPLACE"."AndExpression_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_AndExpressionAudit_ValidFrom" ON "Iteration_REPLACE"."AndExpression_Audit" ("ValidFrom");
CREATE INDEX "Idx_AndExpressionAudit_ValidTo" ON "Iteration_REPLACE"."AndExpression_Audit" ("ValidTo");

CREATE TRIGGER AndExpression_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."AndExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER AndExpression_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."AndExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ExclusiveOrExpression"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ExclusiveOrExpression_ValidFrom" ON "Iteration_REPLACE"."ExclusiveOrExpression" ("ValidFrom");
CREATE INDEX "Idx_ExclusiveOrExpression_ValidTo" ON "Iteration_REPLACE"."ExclusiveOrExpression" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ExclusiveOrExpression_Audit" (LIKE "Iteration_REPLACE"."ExclusiveOrExpression");
ALTER TABLE "Iteration_REPLACE"."ExclusiveOrExpression_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ExclusiveOrExpressionAudit_ValidFrom" ON "Iteration_REPLACE"."ExclusiveOrExpression_Audit" ("ValidFrom");
CREATE INDEX "Idx_ExclusiveOrExpressionAudit_ValidTo" ON "Iteration_REPLACE"."ExclusiveOrExpression_Audit" ("ValidTo");

CREATE TRIGGER ExclusiveOrExpression_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ExclusiveOrExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ExclusiveOrExpression_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ExclusiveOrExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."RelationalExpression"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RelationalExpression_ValidFrom" ON "Iteration_REPLACE"."RelationalExpression" ("ValidFrom");
CREATE INDEX "Idx_RelationalExpression_ValidTo" ON "Iteration_REPLACE"."RelationalExpression" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RelationalExpression_Audit" (LIKE "Iteration_REPLACE"."RelationalExpression");
ALTER TABLE "Iteration_REPLACE"."RelationalExpression_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RelationalExpressionAudit_ValidFrom" ON "Iteration_REPLACE"."RelationalExpression_Audit" ("ValidFrom");
CREATE INDEX "Idx_RelationalExpressionAudit_ValidTo" ON "Iteration_REPLACE"."RelationalExpression_Audit" ("ValidTo");

CREATE TRIGGER RelationalExpression_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RelationalExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RelationalExpression_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RelationalExpression"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."FileStore"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_FileStore_ValidFrom" ON "Iteration_REPLACE"."FileStore" ("ValidFrom");
CREATE INDEX "Idx_FileStore_ValidTo" ON "Iteration_REPLACE"."FileStore" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."FileStore_Audit" (LIKE "Iteration_REPLACE"."FileStore");
ALTER TABLE "Iteration_REPLACE"."FileStore_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_FileStoreAudit_ValidFrom" ON "Iteration_REPLACE"."FileStore_Audit" ("ValidFrom");
CREATE INDEX "Idx_FileStoreAudit_ValidTo" ON "Iteration_REPLACE"."FileStore_Audit" ("ValidTo");

CREATE TRIGGER FileStore_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."FileStore"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER FileStore_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."FileStore"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."DomainFileStore"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DomainFileStore_ValidFrom" ON "Iteration_REPLACE"."DomainFileStore" ("ValidFrom");
CREATE INDEX "Idx_DomainFileStore_ValidTo" ON "Iteration_REPLACE"."DomainFileStore" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."DomainFileStore_Audit" (LIKE "Iteration_REPLACE"."DomainFileStore");
ALTER TABLE "Iteration_REPLACE"."DomainFileStore_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DomainFileStoreAudit_ValidFrom" ON "Iteration_REPLACE"."DomainFileStore_Audit" ("ValidFrom");
CREATE INDEX "Idx_DomainFileStoreAudit_ValidTo" ON "Iteration_REPLACE"."DomainFileStore_Audit" ("ValidTo");

CREATE TRIGGER DomainFileStore_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."DomainFileStore"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DomainFileStore_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."DomainFileStore"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Folder"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Folder_ValidFrom" ON "Iteration_REPLACE"."Folder" ("ValidFrom");
CREATE INDEX "Idx_Folder_ValidTo" ON "Iteration_REPLACE"."Folder" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Folder_Audit" (LIKE "Iteration_REPLACE"."Folder");
ALTER TABLE "Iteration_REPLACE"."Folder_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_FolderAudit_ValidFrom" ON "Iteration_REPLACE"."Folder_Audit" ("ValidFrom");
CREATE INDEX "Idx_FolderAudit_ValidTo" ON "Iteration_REPLACE"."Folder_Audit" ("ValidTo");

CREATE TRIGGER Folder_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Folder"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Folder_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Folder"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."File"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_File_ValidFrom" ON "Iteration_REPLACE"."File" ("ValidFrom");
CREATE INDEX "Idx_File_ValidTo" ON "Iteration_REPLACE"."File" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."File_Audit" (LIKE "Iteration_REPLACE"."File");
ALTER TABLE "Iteration_REPLACE"."File_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_FileAudit_ValidFrom" ON "Iteration_REPLACE"."File_Audit" ("ValidFrom");
CREATE INDEX "Idx_FileAudit_ValidTo" ON "Iteration_REPLACE"."File_Audit" ("ValidTo");

CREATE TRIGGER File_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."File"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER File_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."File"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."FileRevision"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_FileRevision_ValidFrom" ON "Iteration_REPLACE"."FileRevision" ("ValidFrom");
CREATE INDEX "Idx_FileRevision_ValidTo" ON "Iteration_REPLACE"."FileRevision" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."FileRevision_Audit" (LIKE "Iteration_REPLACE"."FileRevision");
ALTER TABLE "Iteration_REPLACE"."FileRevision_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_FileRevisionAudit_ValidFrom" ON "Iteration_REPLACE"."FileRevision_Audit" ("ValidFrom");
CREATE INDEX "Idx_FileRevisionAudit_ValidTo" ON "Iteration_REPLACE"."FileRevision_Audit" ("ValidTo");

CREATE TRIGGER FileRevision_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."FileRevision"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER FileRevision_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."FileRevision"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ActualFiniteStateList_ValidFrom" ON "Iteration_REPLACE"."ActualFiniteStateList" ("ValidFrom");
CREATE INDEX "Idx_ActualFiniteStateList_ValidTo" ON "Iteration_REPLACE"."ActualFiniteStateList" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ActualFiniteStateList_Audit" (LIKE "Iteration_REPLACE"."ActualFiniteStateList");
ALTER TABLE "Iteration_REPLACE"."ActualFiniteStateList_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ActualFiniteStateListAudit_ValidFrom" ON "Iteration_REPLACE"."ActualFiniteStateList_Audit" ("ValidFrom");
CREATE INDEX "Idx_ActualFiniteStateListAudit_ValidTo" ON "Iteration_REPLACE"."ActualFiniteStateList_Audit" ("ValidTo");

CREATE TRIGGER ActualFiniteStateList_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ActualFiniteStateList"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ActualFiniteStateList_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ActualFiniteStateList"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ActualFiniteState"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ActualFiniteState_ValidFrom" ON "Iteration_REPLACE"."ActualFiniteState" ("ValidFrom");
CREATE INDEX "Idx_ActualFiniteState_ValidTo" ON "Iteration_REPLACE"."ActualFiniteState" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ActualFiniteState_Audit" (LIKE "Iteration_REPLACE"."ActualFiniteState");
ALTER TABLE "Iteration_REPLACE"."ActualFiniteState_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ActualFiniteStateAudit_ValidFrom" ON "Iteration_REPLACE"."ActualFiniteState_Audit" ("ValidFrom");
CREATE INDEX "Idx_ActualFiniteStateAudit_ValidTo" ON "Iteration_REPLACE"."ActualFiniteState_Audit" ("ValidTo");

CREATE TRIGGER ActualFiniteState_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ActualFiniteState"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ActualFiniteState_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ActualFiniteState"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."RuleVerificationList"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RuleVerificationList_ValidFrom" ON "Iteration_REPLACE"."RuleVerificationList" ("ValidFrom");
CREATE INDEX "Idx_RuleVerificationList_ValidTo" ON "Iteration_REPLACE"."RuleVerificationList" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RuleVerificationList_Audit" (LIKE "Iteration_REPLACE"."RuleVerificationList");
ALTER TABLE "Iteration_REPLACE"."RuleVerificationList_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RuleVerificationListAudit_ValidFrom" ON "Iteration_REPLACE"."RuleVerificationList_Audit" ("ValidFrom");
CREATE INDEX "Idx_RuleVerificationListAudit_ValidTo" ON "Iteration_REPLACE"."RuleVerificationList_Audit" ("ValidTo");

CREATE TRIGGER RuleVerificationList_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RuleVerificationList"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RuleVerificationList_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RuleVerificationList"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."RuleVerification"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RuleVerification_ValidFrom" ON "Iteration_REPLACE"."RuleVerification" ("ValidFrom");
CREATE INDEX "Idx_RuleVerification_ValidTo" ON "Iteration_REPLACE"."RuleVerification" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RuleVerification_Audit" (LIKE "Iteration_REPLACE"."RuleVerification");
ALTER TABLE "Iteration_REPLACE"."RuleVerification_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RuleVerificationAudit_ValidFrom" ON "Iteration_REPLACE"."RuleVerification_Audit" ("ValidFrom");
CREATE INDEX "Idx_RuleVerificationAudit_ValidTo" ON "Iteration_REPLACE"."RuleVerification_Audit" ("ValidTo");

CREATE TRIGGER RuleVerification_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RuleVerification"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RuleVerification_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RuleVerification"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."UserRuleVerification"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_UserRuleVerification_ValidFrom" ON "Iteration_REPLACE"."UserRuleVerification" ("ValidFrom");
CREATE INDEX "Idx_UserRuleVerification_ValidTo" ON "Iteration_REPLACE"."UserRuleVerification" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."UserRuleVerification_Audit" (LIKE "Iteration_REPLACE"."UserRuleVerification");
ALTER TABLE "Iteration_REPLACE"."UserRuleVerification_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_UserRuleVerificationAudit_ValidFrom" ON "Iteration_REPLACE"."UserRuleVerification_Audit" ("ValidFrom");
CREATE INDEX "Idx_UserRuleVerificationAudit_ValidTo" ON "Iteration_REPLACE"."UserRuleVerification_Audit" ("ValidTo");

CREATE TRIGGER UserRuleVerification_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."UserRuleVerification"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER UserRuleVerification_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."UserRuleVerification"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."RuleViolation"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_RuleViolation_ValidFrom" ON "Iteration_REPLACE"."RuleViolation" ("ValidFrom");
CREATE INDEX "Idx_RuleViolation_ValidTo" ON "Iteration_REPLACE"."RuleViolation" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."RuleViolation_Audit" (LIKE "Iteration_REPLACE"."RuleViolation");
ALTER TABLE "Iteration_REPLACE"."RuleViolation_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_RuleViolationAudit_ValidFrom" ON "Iteration_REPLACE"."RuleViolation_Audit" ("ValidFrom");
CREATE INDEX "Idx_RuleViolationAudit_ValidTo" ON "Iteration_REPLACE"."RuleViolation_Audit" ("ValidTo");

CREATE TRIGGER RuleViolation_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."RuleViolation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER RuleViolation_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."RuleViolation"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."BuiltInRuleVerification"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_BuiltInRuleVerification_ValidFrom" ON "Iteration_REPLACE"."BuiltInRuleVerification" ("ValidFrom");
CREATE INDEX "Idx_BuiltInRuleVerification_ValidTo" ON "Iteration_REPLACE"."BuiltInRuleVerification" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."BuiltInRuleVerification_Audit" (LIKE "Iteration_REPLACE"."BuiltInRuleVerification");
ALTER TABLE "Iteration_REPLACE"."BuiltInRuleVerification_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_BuiltInRuleVerificationAudit_ValidFrom" ON "Iteration_REPLACE"."BuiltInRuleVerification_Audit" ("ValidFrom");
CREATE INDEX "Idx_BuiltInRuleVerificationAudit_ValidTo" ON "Iteration_REPLACE"."BuiltInRuleVerification_Audit" ("ValidTo");

CREATE TRIGGER BuiltInRuleVerification_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."BuiltInRuleVerification"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER BuiltInRuleVerification_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."BuiltInRuleVerification"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Stakeholder"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Stakeholder_ValidFrom" ON "Iteration_REPLACE"."Stakeholder" ("ValidFrom");
CREATE INDEX "Idx_Stakeholder_ValidTo" ON "Iteration_REPLACE"."Stakeholder" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Stakeholder_Audit" (LIKE "Iteration_REPLACE"."Stakeholder");
ALTER TABLE "Iteration_REPLACE"."Stakeholder_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_StakeholderAudit_ValidFrom" ON "Iteration_REPLACE"."Stakeholder_Audit" ("ValidFrom");
CREATE INDEX "Idx_StakeholderAudit_ValidTo" ON "Iteration_REPLACE"."Stakeholder_Audit" ("ValidTo");

CREATE TRIGGER Stakeholder_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Stakeholder"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Stakeholder_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Stakeholder"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Goal"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Goal_ValidFrom" ON "Iteration_REPLACE"."Goal" ("ValidFrom");
CREATE INDEX "Idx_Goal_ValidTo" ON "Iteration_REPLACE"."Goal" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Goal_Audit" (LIKE "Iteration_REPLACE"."Goal");
ALTER TABLE "Iteration_REPLACE"."Goal_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_GoalAudit_ValidFrom" ON "Iteration_REPLACE"."Goal_Audit" ("ValidFrom");
CREATE INDEX "Idx_GoalAudit_ValidTo" ON "Iteration_REPLACE"."Goal_Audit" ("ValidTo");

CREATE TRIGGER Goal_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Goal"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Goal_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Goal"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."ValueGroup"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_ValueGroup_ValidFrom" ON "Iteration_REPLACE"."ValueGroup" ("ValidFrom");
CREATE INDEX "Idx_ValueGroup_ValidTo" ON "Iteration_REPLACE"."ValueGroup" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."ValueGroup_Audit" (LIKE "Iteration_REPLACE"."ValueGroup");
ALTER TABLE "Iteration_REPLACE"."ValueGroup_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ValueGroupAudit_ValidFrom" ON "Iteration_REPLACE"."ValueGroup_Audit" ("ValidFrom");
CREATE INDEX "Idx_ValueGroupAudit_ValidTo" ON "Iteration_REPLACE"."ValueGroup_Audit" ("ValidTo");

CREATE TRIGGER ValueGroup_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."ValueGroup"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER ValueGroup_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."ValueGroup"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."StakeholderValue"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_StakeholderValue_ValidFrom" ON "Iteration_REPLACE"."StakeholderValue" ("ValidFrom");
CREATE INDEX "Idx_StakeholderValue_ValidTo" ON "Iteration_REPLACE"."StakeholderValue" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."StakeholderValue_Audit" (LIKE "Iteration_REPLACE"."StakeholderValue");
ALTER TABLE "Iteration_REPLACE"."StakeholderValue_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_StakeholderValueAudit_ValidFrom" ON "Iteration_REPLACE"."StakeholderValue_Audit" ("ValidFrom");
CREATE INDEX "Idx_StakeholderValueAudit_ValidTo" ON "Iteration_REPLACE"."StakeholderValue_Audit" ("ValidTo");

CREATE TRIGGER StakeholderValue_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."StakeholderValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER StakeholderValue_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."StakeholderValue"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_StakeHolderValueMap_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMap_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMap_Audit" (LIKE "Iteration_REPLACE"."StakeHolderValueMap");
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMap_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_StakeHolderValueMapAudit_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMap_Audit" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMapAudit_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMap_Audit" ("ValidTo");

CREATE TRIGGER StakeHolderValueMap_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."StakeHolderValueMap"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER StakeHolderValueMap_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."StakeHolderValueMap"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_StakeHolderValueMapSettings_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMapSettings" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMapSettings_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMapSettings" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings_Audit" (LIKE "Iteration_REPLACE"."StakeHolderValueMapSettings");
ALTER TABLE "Iteration_REPLACE"."StakeHolderValueMapSettings_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_StakeHolderValueMapSettingsAudit_ValidFrom" ON "Iteration_REPLACE"."StakeHolderValueMapSettings_Audit" ("ValidFrom");
CREATE INDEX "Idx_StakeHolderValueMapSettingsAudit_ValidTo" ON "Iteration_REPLACE"."StakeHolderValueMapSettings_Audit" ("ValidTo");

CREATE TRIGGER StakeHolderValueMapSettings_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."StakeHolderValueMapSettings"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER StakeHolderValueMapSettings_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."StakeHolderValueMapSettings"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."DiagramThingBase"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DiagramThingBase_ValidFrom" ON "Iteration_REPLACE"."DiagramThingBase" ("ValidFrom");
CREATE INDEX "Idx_DiagramThingBase_ValidTo" ON "Iteration_REPLACE"."DiagramThingBase" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."DiagramThingBase_Audit" (LIKE "Iteration_REPLACE"."DiagramThingBase");
ALTER TABLE "Iteration_REPLACE"."DiagramThingBase_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DiagramThingBaseAudit_ValidFrom" ON "Iteration_REPLACE"."DiagramThingBase_Audit" ("ValidFrom");
CREATE INDEX "Idx_DiagramThingBaseAudit_ValidTo" ON "Iteration_REPLACE"."DiagramThingBase_Audit" ("ValidTo");

CREATE TRIGGER DiagramThingBase_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."DiagramThingBase"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DiagramThingBase_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."DiagramThingBase"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."DiagrammingStyle"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DiagrammingStyle_ValidFrom" ON "Iteration_REPLACE"."DiagrammingStyle" ("ValidFrom");
CREATE INDEX "Idx_DiagrammingStyle_ValidTo" ON "Iteration_REPLACE"."DiagrammingStyle" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."DiagrammingStyle_Audit" (LIKE "Iteration_REPLACE"."DiagrammingStyle");
ALTER TABLE "Iteration_REPLACE"."DiagrammingStyle_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DiagrammingStyleAudit_ValidFrom" ON "Iteration_REPLACE"."DiagrammingStyle_Audit" ("ValidFrom");
CREATE INDEX "Idx_DiagrammingStyleAudit_ValidTo" ON "Iteration_REPLACE"."DiagrammingStyle_Audit" ("ValidTo");

CREATE TRIGGER DiagrammingStyle_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."DiagrammingStyle"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DiagrammingStyle_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."DiagrammingStyle"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."SharedStyle"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_SharedStyle_ValidFrom" ON "Iteration_REPLACE"."SharedStyle" ("ValidFrom");
CREATE INDEX "Idx_SharedStyle_ValidTo" ON "Iteration_REPLACE"."SharedStyle" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."SharedStyle_Audit" (LIKE "Iteration_REPLACE"."SharedStyle");
ALTER TABLE "Iteration_REPLACE"."SharedStyle_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_SharedStyleAudit_ValidFrom" ON "Iteration_REPLACE"."SharedStyle_Audit" ("ValidFrom");
CREATE INDEX "Idx_SharedStyleAudit_ValidTo" ON "Iteration_REPLACE"."SharedStyle_Audit" ("ValidTo");

CREATE TRIGGER SharedStyle_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."SharedStyle"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER SharedStyle_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."SharedStyle"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Color"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Color_ValidFrom" ON "Iteration_REPLACE"."Color" ("ValidFrom");
CREATE INDEX "Idx_Color_ValidTo" ON "Iteration_REPLACE"."Color" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Color_Audit" (LIKE "Iteration_REPLACE"."Color");
ALTER TABLE "Iteration_REPLACE"."Color_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_ColorAudit_ValidFrom" ON "Iteration_REPLACE"."Color_Audit" ("ValidFrom");
CREATE INDEX "Idx_ColorAudit_ValidTo" ON "Iteration_REPLACE"."Color_Audit" ("ValidTo");

CREATE TRIGGER Color_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Color"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Color_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Color"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."DiagramElementContainer"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DiagramElementContainer_ValidFrom" ON "Iteration_REPLACE"."DiagramElementContainer" ("ValidFrom");
CREATE INDEX "Idx_DiagramElementContainer_ValidTo" ON "Iteration_REPLACE"."DiagramElementContainer" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."DiagramElementContainer_Audit" (LIKE "Iteration_REPLACE"."DiagramElementContainer");
ALTER TABLE "Iteration_REPLACE"."DiagramElementContainer_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DiagramElementContainerAudit_ValidFrom" ON "Iteration_REPLACE"."DiagramElementContainer_Audit" ("ValidFrom");
CREATE INDEX "Idx_DiagramElementContainerAudit_ValidTo" ON "Iteration_REPLACE"."DiagramElementContainer_Audit" ("ValidTo");

CREATE TRIGGER DiagramElementContainer_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."DiagramElementContainer"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DiagramElementContainer_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."DiagramElementContainer"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."DiagramCanvas"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DiagramCanvas_ValidFrom" ON "Iteration_REPLACE"."DiagramCanvas" ("ValidFrom");
CREATE INDEX "Idx_DiagramCanvas_ValidTo" ON "Iteration_REPLACE"."DiagramCanvas" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."DiagramCanvas_Audit" (LIKE "Iteration_REPLACE"."DiagramCanvas");
ALTER TABLE "Iteration_REPLACE"."DiagramCanvas_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DiagramCanvasAudit_ValidFrom" ON "Iteration_REPLACE"."DiagramCanvas_Audit" ("ValidFrom");
CREATE INDEX "Idx_DiagramCanvasAudit_ValidTo" ON "Iteration_REPLACE"."DiagramCanvas_Audit" ("ValidTo");

CREATE TRIGGER DiagramCanvas_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."DiagramCanvas"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DiagramCanvas_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."DiagramCanvas"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."DiagramElementThing"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DiagramElementThing_ValidFrom" ON "Iteration_REPLACE"."DiagramElementThing" ("ValidFrom");
CREATE INDEX "Idx_DiagramElementThing_ValidTo" ON "Iteration_REPLACE"."DiagramElementThing" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."DiagramElementThing_Audit" (LIKE "Iteration_REPLACE"."DiagramElementThing");
ALTER TABLE "Iteration_REPLACE"."DiagramElementThing_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DiagramElementThingAudit_ValidFrom" ON "Iteration_REPLACE"."DiagramElementThing_Audit" ("ValidFrom");
CREATE INDEX "Idx_DiagramElementThingAudit_ValidTo" ON "Iteration_REPLACE"."DiagramElementThing_Audit" ("ValidTo");

CREATE TRIGGER DiagramElementThing_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."DiagramElementThing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DiagramElementThing_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."DiagramElementThing"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."DiagramEdge"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DiagramEdge_ValidFrom" ON "Iteration_REPLACE"."DiagramEdge" ("ValidFrom");
CREATE INDEX "Idx_DiagramEdge_ValidTo" ON "Iteration_REPLACE"."DiagramEdge" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."DiagramEdge_Audit" (LIKE "Iteration_REPLACE"."DiagramEdge");
ALTER TABLE "Iteration_REPLACE"."DiagramEdge_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DiagramEdgeAudit_ValidFrom" ON "Iteration_REPLACE"."DiagramEdge_Audit" ("ValidFrom");
CREATE INDEX "Idx_DiagramEdgeAudit_ValidTo" ON "Iteration_REPLACE"."DiagramEdge_Audit" ("ValidTo");

CREATE TRIGGER DiagramEdge_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."DiagramEdge"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DiagramEdge_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."DiagramEdge"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Bounds"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Bounds_ValidFrom" ON "Iteration_REPLACE"."Bounds" ("ValidFrom");
CREATE INDEX "Idx_Bounds_ValidTo" ON "Iteration_REPLACE"."Bounds" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Bounds_Audit" (LIKE "Iteration_REPLACE"."Bounds");
ALTER TABLE "Iteration_REPLACE"."Bounds_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_BoundsAudit_ValidFrom" ON "Iteration_REPLACE"."Bounds_Audit" ("ValidFrom");
CREATE INDEX "Idx_BoundsAudit_ValidTo" ON "Iteration_REPLACE"."Bounds_Audit" ("ValidTo");

CREATE TRIGGER Bounds_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Bounds"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Bounds_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Bounds"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."OwnedStyle"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_OwnedStyle_ValidFrom" ON "Iteration_REPLACE"."OwnedStyle" ("ValidFrom");
CREATE INDEX "Idx_OwnedStyle_ValidTo" ON "Iteration_REPLACE"."OwnedStyle" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."OwnedStyle_Audit" (LIKE "Iteration_REPLACE"."OwnedStyle");
ALTER TABLE "Iteration_REPLACE"."OwnedStyle_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_OwnedStyleAudit_ValidFrom" ON "Iteration_REPLACE"."OwnedStyle_Audit" ("ValidFrom");
CREATE INDEX "Idx_OwnedStyleAudit_ValidTo" ON "Iteration_REPLACE"."OwnedStyle_Audit" ("ValidTo");

CREATE TRIGGER OwnedStyle_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."OwnedStyle"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER OwnedStyle_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."OwnedStyle"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."Point"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_Point_ValidFrom" ON "Iteration_REPLACE"."Point" ("ValidFrom");
CREATE INDEX "Idx_Point_ValidTo" ON "Iteration_REPLACE"."Point" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."Point_Audit" (LIKE "Iteration_REPLACE"."Point");
ALTER TABLE "Iteration_REPLACE"."Point_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_PointAudit_ValidFrom" ON "Iteration_REPLACE"."Point_Audit" ("ValidFrom");
CREATE INDEX "Idx_PointAudit_ValidTo" ON "Iteration_REPLACE"."Point_Audit" ("ValidTo");

CREATE TRIGGER Point_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."Point"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER Point_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."Point"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."DiagramShape"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DiagramShape_ValidFrom" ON "Iteration_REPLACE"."DiagramShape" ("ValidFrom");
CREATE INDEX "Idx_DiagramShape_ValidTo" ON "Iteration_REPLACE"."DiagramShape" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."DiagramShape_Audit" (LIKE "Iteration_REPLACE"."DiagramShape");
ALTER TABLE "Iteration_REPLACE"."DiagramShape_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DiagramShapeAudit_ValidFrom" ON "Iteration_REPLACE"."DiagramShape_Audit" ("ValidFrom");
CREATE INDEX "Idx_DiagramShapeAudit_ValidTo" ON "Iteration_REPLACE"."DiagramShape_Audit" ("ValidTo");

CREATE TRIGGER DiagramShape_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."DiagramShape"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DiagramShape_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."DiagramShape"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
ALTER TABLE "Iteration_REPLACE"."DiagramObject"
  ADD COLUMN "ValidFrom" timestamp DEFAULT "SiteDirectory".get_transaction_time() NOT NULL,
  ADD COLUMN "ValidTo" timestamp DEFAULT 'infinity' NOT NULL;
CREATE INDEX "Idx_DiagramObject_ValidFrom" ON "Iteration_REPLACE"."DiagramObject" ("ValidFrom");
CREATE INDEX "Idx_DiagramObject_ValidTo" ON "Iteration_REPLACE"."DiagramObject" ("ValidTo");

CREATE TABLE "Iteration_REPLACE"."DiagramObject_Audit" (LIKE "Iteration_REPLACE"."DiagramObject");
ALTER TABLE "Iteration_REPLACE"."DiagramObject_Audit" 
  ADD COLUMN "Action" character(1) NOT NULL,
  ADD COLUMN "Actor" uuid;
CREATE INDEX "Idx_DiagramObjectAudit_ValidFrom" ON "Iteration_REPLACE"."DiagramObject_Audit" ("ValidFrom");
CREATE INDEX "Idx_DiagramObjectAudit_ValidTo" ON "Iteration_REPLACE"."DiagramObject_Audit" ("ValidTo");

CREATE TRIGGER DiagramObject_audit_prepare
  BEFORE UPDATE ON "Iteration_REPLACE"."DiagramObject"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_before();

CREATE TRIGGER DiagramObject_audit_log
  AFTER INSERT OR UPDATE OR DELETE ON "Iteration_REPLACE"."DiagramObject"
  FOR EACH ROW 
  EXECUTE PROCEDURE "SiteDirectory".process_timetravel_after();
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Thing_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Thing" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Thing";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Thing"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Thing_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."TopContainer_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."TopContainer" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."TopContainer";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."TopContainer"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."TopContainer_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."EngineeringModel_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."EngineeringModel" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."EngineeringModel";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","EngineeringModelSetup","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."EngineeringModel"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","EngineeringModelSetup","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."EngineeringModel_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."FileStore_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."FileStore" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."FileStore";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Owner","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."FileStore"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Owner","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."FileStore_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."CommonFileStore_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."CommonFileStore" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."CommonFileStore";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."CommonFileStore"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."CommonFileStore_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Folder_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Folder" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Folder";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Creator","ContainingFolder","Owner","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Folder"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Creator","ContainingFolder","Owner","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Folder_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."File_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."File" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."File";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","LockedBy","Owner","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."File"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","LockedBy","Owner","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."File_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."FileRevision_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."FileRevision" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."FileRevision";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Creator","ContainingFolder","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."FileRevision"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Creator","ContainingFolder","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."FileRevision_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ModelLogEntry_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ModelLogEntry" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ModelLogEntry";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Author","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ModelLogEntry"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Author","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ModelLogEntry_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Iteration_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Iteration" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Iteration";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","IterationSetup","TopElement","DefaultOption","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Iteration"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","IterationSetup","TopElement","DefaultOption","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Iteration_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Book_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Book" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Book";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Sequence","Owner","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Book"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Sequence","Owner","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Book_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Section_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Section" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Section";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Sequence","Owner","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Section"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Sequence","Owner","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Section_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Page_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Page" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Page";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Sequence","Owner","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Page"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Sequence","Owner","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Page_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Note_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Note" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Note";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Sequence","Owner","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Note"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Sequence","Owner","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Note_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."BinaryNote_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."BinaryNote" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."BinaryNote";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","FileType","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."BinaryNote"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","FileType","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."BinaryNote_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."TextualNote_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."TextualNote" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."TextualNote";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."TextualNote"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."TextualNote_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."GenericAnnotation_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."GenericAnnotation" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."GenericAnnotation";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."GenericAnnotation"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."GenericAnnotation_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Author","PrimaryAnnotatedThing","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Author","PrimaryAnnotatedThing","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."EngineeringModelDataNote_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."EngineeringModelDataNote" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataNote";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."EngineeringModelDataNote"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."EngineeringModelDataNote_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ThingReference_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ThingReference" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ThingReference";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ReferencedThing","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ThingReference"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ReferencedThing","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ThingReference_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ModellingThingReference_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ModellingThingReference" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ModellingThingReference";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ModellingThingReference"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ModellingThingReference_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."DiscussionItem_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."DiscussionItem" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."DiscussionItem";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ReplyTo","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."DiscussionItem"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ReplyTo","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."DiscussionItem_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Author","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Author","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ModellingAnnotationItem" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Owner","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Owner","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ContractDeviation_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ContractDeviation" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ContractDeviation";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ContractDeviation"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ContractDeviation_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."RequestForWaiver_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."RequestForWaiver" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."RequestForWaiver";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."RequestForWaiver"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."RequestForWaiver_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Approval_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Approval" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Approval";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Author","Owner","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Approval"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Author","Owner","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Approval_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."RequestForDeviation_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."RequestForDeviation" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."RequestForDeviation";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."RequestForDeviation"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."RequestForDeviation_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ChangeRequest_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ChangeRequest" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ChangeRequest";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ChangeRequest"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ChangeRequest_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ReviewItemDiscrepancy" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ReviewItemDiscrepancy";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ReviewItemDiscrepancy"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Solution_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Solution" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Solution";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Author","Owner","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Solution"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Author","Owner","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Solution_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ActionItem_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ActionItem" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ActionItem";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Actionee","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ActionItem"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Actionee","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ActionItem_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ChangeProposal_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ChangeProposal" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ChangeProposal";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ChangeRequest","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ChangeProposal"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ChangeRequest","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ChangeProposal_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ContractChangeNotice_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ContractChangeNotice" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ContractChangeNotice";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ChangeProposal","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ContractChangeNotice"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ChangeProposal","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ContractChangeNotice_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Thing_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Thing" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Thing";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Thing"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Thing_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."DefinedThing_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."DefinedThing" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."DefinedThing";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."DefinedThing"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."DefinedThing_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Option_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Option" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Option";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Sequence","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Option"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Sequence","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Option_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Alias_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Alias" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Alias";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Alias"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Alias_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Definition_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Definition" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Definition";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Definition"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Definition_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Citation_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Citation" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Citation";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Source","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Citation"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Source","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Citation_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."HyperLink_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."HyperLink" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."HyperLink";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."HyperLink"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."HyperLink_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."NestedElement_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."NestedElement" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."NestedElement";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","RootElement","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."NestedElement"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","RootElement","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."NestedElement_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."NestedParameter_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."NestedParameter" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."NestedParameter";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","AssociatedParameter","ActualState","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."NestedParameter"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","AssociatedParameter","ActualState","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."NestedParameter_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Publication_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Publication" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Publication";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Publication"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Publication_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."PossibleFiniteStateList_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."PossibleFiniteStateList" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."PossibleFiniteStateList";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","DefaultState","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."PossibleFiniteStateList"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","DefaultState","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."PossibleFiniteStateList_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."PossibleFiniteState_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."PossibleFiniteState" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."PossibleFiniteState";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Sequence","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."PossibleFiniteState"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Sequence","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."PossibleFiniteState_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ElementBase_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ElementBase" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ElementBase";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ElementBase"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ElementBase_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ElementDefinition_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ElementDefinition" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ElementDefinition";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ElementDefinition"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ElementDefinition_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ElementUsage_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ElementUsage" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ElementUsage";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ElementDefinition","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ElementUsage"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ElementDefinition","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ElementUsage_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParameterBase_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParameterBase" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParameterBase";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ParameterType","Scale","StateDependence","Group","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParameterBase"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ParameterType","Scale","StateDependence","Group","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParameterBase_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParameterOrOverrideBase_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParameterOrOverrideBase" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParameterOrOverrideBase";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParameterOrOverrideBase"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParameterOrOverrideBase_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParameterOverride_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParameterOverride" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParameterOverride";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Parameter","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParameterOverride"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Parameter","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParameterOverride_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParameterSubscription_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParameterSubscription" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParameterSubscription";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParameterSubscription"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParameterSubscription_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParameterSubscriptionValueSet_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParameterSubscriptionValueSet" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParameterSubscriptionValueSet";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","SubscribedValueSet","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParameterSubscriptionValueSet"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","SubscribedValueSet","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParameterSubscriptionValueSet_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParameterValueSetBase_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParameterValueSetBase" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParameterValueSetBase";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ActualState","ActualOption","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParameterValueSetBase"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ActualState","ActualOption","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParameterValueSetBase_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParameterOverrideValueSet_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParameterOverrideValueSet" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParameterOverrideValueSet";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ParameterValueSet","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParameterOverrideValueSet"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ParameterValueSet","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParameterOverrideValueSet_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Parameter_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Parameter" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Parameter";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","RequestedBy","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Parameter"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","RequestedBy","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Parameter_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParameterValueSet_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParameterValueSet" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParameterValueSet";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParameterValueSet"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParameterValueSet_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParameterGroup_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParameterGroup" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParameterGroup";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ContainingGroup","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParameterGroup"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ContainingGroup","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParameterGroup_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Relationship_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Relationship" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Relationship";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Relationship"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Relationship_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."MultiRelationship_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."MultiRelationship" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."MultiRelationship";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."MultiRelationship"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."MultiRelationship_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParameterValue_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParameterValue" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParameterValue";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ParameterType","Scale","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParameterValue"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ParameterType","Scale","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParameterValue_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RelationshipParameterValue_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RelationshipParameterValue" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RelationshipParameterValue";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RelationshipParameterValue"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RelationshipParameterValue_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."BinaryRelationship_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."BinaryRelationship" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."BinaryRelationship";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Source","Target","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."BinaryRelationship"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Source","Target","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."BinaryRelationship_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ExternalIdentifierMap_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ExternalIdentifierMap" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ExternalIdentifierMap";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ExternalFormat","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ExternalIdentifierMap"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ExternalFormat","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ExternalIdentifierMap_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."IdCorrespondence_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."IdCorrespondence" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."IdCorrespondence";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."IdCorrespondence"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."IdCorrespondence_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RequirementsContainer_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RequirementsContainer" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RequirementsContainer";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RequirementsContainer"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RequirementsContainer_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RequirementsSpecification_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RequirementsSpecification" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RequirementsSpecification";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RequirementsSpecification"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RequirementsSpecification_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RequirementsGroup_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RequirementsGroup" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RequirementsGroup";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RequirementsGroup"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RequirementsGroup_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RequirementsContainerParameterValue_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RequirementsContainerParameterValue" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RequirementsContainerParameterValue";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RequirementsContainerParameterValue"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RequirementsContainerParameterValue_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."SimpleParameterizableThing_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."SimpleParameterizableThing" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."SimpleParameterizableThing";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."SimpleParameterizableThing"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."SimpleParameterizableThing_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Requirement_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Requirement" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Requirement";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Group","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Requirement"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Group","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Requirement_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."SimpleParameterValue_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."SimpleParameterValue" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."SimpleParameterValue";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ParameterType","Scale","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."SimpleParameterValue"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ParameterType","Scale","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."SimpleParameterValue_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ParametricConstraint_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ParametricConstraint" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ParametricConstraint";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Sequence","TopExpression","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ParametricConstraint"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Sequence","TopExpression","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ParametricConstraint_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."BooleanExpression_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."BooleanExpression" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."BooleanExpression";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."BooleanExpression"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."BooleanExpression_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."OrExpression_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."OrExpression" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."OrExpression";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."OrExpression"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."OrExpression_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."NotExpression_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."NotExpression" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."NotExpression";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Term","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."NotExpression"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Term","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."NotExpression_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."AndExpression_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."AndExpression" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."AndExpression";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."AndExpression"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."AndExpression_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ExclusiveOrExpression_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ExclusiveOrExpression" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ExclusiveOrExpression";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ExclusiveOrExpression"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ExclusiveOrExpression_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RelationalExpression_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RelationalExpression" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RelationalExpression";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ParameterType","Scale","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RelationalExpression"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ParameterType","Scale","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RelationalExpression_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."FileStore_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."FileStore" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."FileStore";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."FileStore"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."FileStore_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."DomainFileStore_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."DomainFileStore" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."DomainFileStore";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."DomainFileStore"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."DomainFileStore_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Folder_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Folder" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Folder";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Creator","ContainingFolder","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Folder"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Creator","ContainingFolder","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Folder_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."File_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."File" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."File";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","LockedBy","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."File"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","LockedBy","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."File_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."FileRevision_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."FileRevision" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."FileRevision";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Creator","ContainingFolder","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."FileRevision"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Creator","ContainingFolder","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."FileRevision_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ActualFiniteStateList_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ActualFiniteStateList" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ActualFiniteStateList";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ActualFiniteStateList"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ActualFiniteStateList_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ActualFiniteState_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ActualFiniteState" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ActualFiniteState";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ActualFiniteState"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ActualFiniteState_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RuleVerificationList_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RuleVerificationList" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RuleVerificationList";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Owner","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RuleVerificationList"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Owner","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RuleVerificationList_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RuleVerification_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RuleVerification" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RuleVerification";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Sequence","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RuleVerification"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Sequence","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RuleVerification_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."UserRuleVerification_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."UserRuleVerification" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."UserRuleVerification";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Rule","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."UserRuleVerification"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Rule","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."UserRuleVerification_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RuleViolation_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RuleViolation" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RuleViolation";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RuleViolation"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RuleViolation_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."BuiltInRuleVerification_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."BuiltInRuleVerification" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."BuiltInRuleVerification";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."BuiltInRuleVerification"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."BuiltInRuleVerification_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Stakeholder_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Stakeholder" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Stakeholder";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Stakeholder"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Stakeholder_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Goal_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Goal" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Goal";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Goal"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Goal_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ValueGroup_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ValueGroup" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ValueGroup";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ValueGroup"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ValueGroup_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."StakeholderValue_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."StakeholderValue" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."StakeholderValue";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."StakeholderValue"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."StakeholderValue_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."StakeHolderValueMap_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."StakeHolderValueMap" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."StakeHolderValueMap";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."StakeHolderValueMap"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."StakeHolderValueMap_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."StakeHolderValueMapSettings_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."StakeHolderValueMapSettings" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."StakeHolderValueMapSettings";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","GoalToValueGroupRelationship","ValueGroupToStakeholderValueRelationship","StakeholderValueToRequirementRelationship","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."StakeHolderValueMapSettings"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","GoalToValueGroupRelationship","ValueGroupToStakeholderValueRelationship","StakeholderValueToRequirementRelationship","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."StakeHolderValueMapSettings_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."DiagramThingBase_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."DiagramThingBase" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."DiagramThingBase";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."DiagramThingBase"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."DiagramThingBase_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."DiagrammingStyle_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."DiagrammingStyle" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."DiagrammingStyle";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","FillColor","StrokeColor","FontColor","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."DiagrammingStyle"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","FillColor","StrokeColor","FontColor","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."DiagrammingStyle_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."SharedStyle_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."SharedStyle" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."SharedStyle";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."SharedStyle"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."SharedStyle_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Color_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Color" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Color";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Color"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Color_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."DiagramElementContainer_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."DiagramElementContainer" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."DiagramElementContainer";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."DiagramElementContainer"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."DiagramElementContainer_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."DiagramCanvas_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."DiagramCanvas" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."DiagramCanvas";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."DiagramCanvas"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."DiagramCanvas_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."DiagramElementThing_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."DiagramElementThing" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."DiagramElementThing";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","DepictedThing","SharedStyle","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."DiagramElementThing"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","DepictedThing","SharedStyle","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."DiagramElementThing_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."DiagramEdge_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."DiagramEdge" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."DiagramEdge";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Source","Target","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."DiagramEdge"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Source","Target","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."DiagramEdge_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Bounds_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Bounds" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Bounds";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Bounds"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Bounds_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."OwnedStyle_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."OwnedStyle" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."OwnedStyle";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."OwnedStyle"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."OwnedStyle_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Point_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Point" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Point";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","Container","Sequence","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Point"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","Container","Sequence","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Point_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."DiagramShape_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."DiagramShape" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."DiagramShape";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."DiagramShape"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."DiagramShape_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."DiagramObject_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."DiagramObject" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."DiagramObject";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."DiagramObject"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Iid","ValueTypeDictionary","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."DiagramObject_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Thing_ExcludedPerson" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Thing","ExcludedPerson","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Thing","ExcludedPerson","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Thing_ExcludedDomain" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Thing","ExcludedDomain","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Thing","ExcludedDomain","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."File_Category_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."File_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."File_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "File","Category","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."File_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "File","Category","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."File_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."FileRevision_FileType_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."FileRevision_FileType" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."FileRevision_FileType";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "FileRevision","FileType","Sequence","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."FileRevision_FileType"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "FileRevision","FileType","Sequence","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."FileRevision_FileType_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ModelLogEntry_Category_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ModelLogEntry_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ModelLogEntry_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ModelLogEntry","Category","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ModelLogEntry_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ModelLogEntry","Category","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ModelLogEntry_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ModelLogEntry","AffectedItemIid","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ModelLogEntry","AffectedItemIid","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Book_Category_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Book_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Book_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Book","Category","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Book_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Book","Category","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Book_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Section_Category_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Section_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Section_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Section","Category","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Section_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Section","Category","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Section_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Page_Category_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Page_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Page_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Page","Category","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Page_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Page","Category","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Page_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."Note_Category_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."Note_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."Note_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Note","Category","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."Note_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Note","Category","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."Note_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ModellingAnnotationItem","SourceAnnotation","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ModellingAnnotationItem","SourceAnnotation","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Data" ()
    RETURNS SETOF "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ModellingAnnotationItem","Category","ValidFrom","ValidTo" 
      FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ModellingAnnotationItem","Category","ValidFrom","ValidTo"
      FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Thing_ExcludedPerson_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Thing_ExcludedPerson" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Thing","ExcludedPerson","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Thing_ExcludedPerson"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Thing","ExcludedPerson","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Thing_ExcludedDomain_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Thing_ExcludedDomain" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Thing","ExcludedDomain","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Thing_ExcludedDomain"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Thing","ExcludedDomain","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Option_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Option_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Option_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Option","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Option_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Option","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Option_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Definition_Note_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Definition_Note" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Definition_Note";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Definition","Note","Sequence","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Definition_Note"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Definition","Note","Sequence","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Definition_Note_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Definition_Example_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Definition_Example" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Definition_Example";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Definition","Example","Sequence","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Definition_Example"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Definition","Example","Sequence","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Definition_Example_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."NestedElement_ElementUsage_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."NestedElement_ElementUsage" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."NestedElement_ElementUsage";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "NestedElement","ElementUsage","Sequence","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."NestedElement_ElementUsage"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "NestedElement","ElementUsage","Sequence","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."NestedElement_ElementUsage_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Publication_Domain_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Publication_Domain" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Publication_Domain";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Publication","Domain","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Publication_Domain"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Publication","Domain","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Publication_Domain_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Publication_PublishedParameter_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Publication_PublishedParameter" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Publication_PublishedParameter";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Publication","PublishedParameter","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Publication_PublishedParameter"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Publication","PublishedParameter","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Publication_PublishedParameter_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."PossibleFiniteStateList_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."PossibleFiniteStateList_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."PossibleFiniteStateList_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "PossibleFiniteStateList","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."PossibleFiniteStateList_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "PossibleFiniteStateList","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."PossibleFiniteStateList_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ElementBase_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ElementBase_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ElementBase_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ElementBase","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ElementBase_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ElementBase","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ElementBase_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ElementDefinition_ReferencedElement_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ElementDefinition_ReferencedElement" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ElementDefinition_ReferencedElement";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ElementDefinition","ReferencedElement","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ElementDefinition_ReferencedElement"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ElementDefinition","ReferencedElement","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ElementDefinition_ReferencedElement_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ElementUsage_ExcludeOption_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ElementUsage_ExcludeOption" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ElementUsage_ExcludeOption";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ElementUsage","ExcludeOption","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ElementUsage_ExcludeOption"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ElementUsage","ExcludeOption","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ElementUsage_ExcludeOption_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Relationship_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Relationship_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Relationship_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Relationship","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Relationship_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Relationship","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Relationship_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."MultiRelationship_RelatedThing_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."MultiRelationship_RelatedThing" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."MultiRelationship_RelatedThing";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "MultiRelationship","RelatedThing","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."MultiRelationship_RelatedThing"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "MultiRelationship","RelatedThing","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."MultiRelationship_RelatedThing_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RequirementsContainer_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RequirementsContainer_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RequirementsContainer_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "RequirementsContainer","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RequirementsContainer_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "RequirementsContainer","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RequirementsContainer_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Requirement_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Requirement_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Requirement_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Requirement","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Requirement_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Requirement","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Requirement_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."OrExpression_Term_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."OrExpression_Term" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."OrExpression_Term";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "OrExpression","Term","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."OrExpression_Term"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "OrExpression","Term","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."OrExpression_Term_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."AndExpression_Term_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."AndExpression_Term" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."AndExpression_Term";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "AndExpression","Term","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."AndExpression_Term"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "AndExpression","Term","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."AndExpression_Term_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ExclusiveOrExpression_Term_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ExclusiveOrExpression_Term" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ExclusiveOrExpression_Term";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ExclusiveOrExpression","Term","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ExclusiveOrExpression_Term"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ExclusiveOrExpression","Term","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ExclusiveOrExpression_Term_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."File_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."File_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."File_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "File","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."File_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "File","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."File_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."FileRevision_FileType_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."FileRevision_FileType" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."FileRevision_FileType";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "FileRevision","FileType","Sequence","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."FileRevision_FileType"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "FileRevision","FileType","Sequence","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."FileRevision_FileType_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ActualFiniteStateList","PossibleFiniteStateList","Sequence","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ActualFiniteStateList","PossibleFiniteStateList","Sequence","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ActualFiniteStateList","ExcludeOption","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ActualFiniteStateList","ExcludeOption","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ActualFiniteState_PossibleState_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ActualFiniteState_PossibleState" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ActualFiniteState_PossibleState";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ActualFiniteState","PossibleState","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ActualFiniteState_PossibleState"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ActualFiniteState","PossibleState","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ActualFiniteState_PossibleState_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."RuleViolation_ViolatingThing_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."RuleViolation_ViolatingThing" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."RuleViolation_ViolatingThing";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "RuleViolation","ViolatingThing","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."RuleViolation_ViolatingThing"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "RuleViolation","ViolatingThing","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."RuleViolation_ViolatingThing_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Stakeholder_StakeholderValue_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Stakeholder_StakeholderValue" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Stakeholder_StakeholderValue";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Stakeholder","StakeholderValue","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Stakeholder_StakeholderValue"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Stakeholder","StakeholderValue","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Stakeholder_StakeholderValue_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Stakeholder_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Stakeholder_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Stakeholder_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Stakeholder","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Stakeholder_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Stakeholder","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Stakeholder_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."Goal_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."Goal_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."Goal_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "Goal","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."Goal_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "Goal","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."Goal_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."ValueGroup_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."ValueGroup_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."ValueGroup_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "ValueGroup","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."ValueGroup_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "ValueGroup","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."ValueGroup_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."StakeholderValue_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."StakeholderValue_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."StakeholderValue_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "StakeholderValue","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."StakeholderValue_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "StakeholderValue","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."StakeholderValue_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."StakeHolderValueMap_Goal_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."StakeHolderValueMap_Goal" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."StakeHolderValueMap_Goal";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "StakeHolderValueMap","Goal","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."StakeHolderValueMap_Goal"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "StakeHolderValueMap","Goal","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."StakeHolderValueMap_Goal_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "StakeHolderValueMap","ValueGroup","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "StakeHolderValueMap","ValueGroup","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "StakeHolderValueMap","StakeholderValue","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "StakeHolderValueMap","StakeholderValue","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."StakeHolderValueMap_Requirement_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."StakeHolderValueMap_Requirement" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."StakeHolderValueMap_Requirement";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "StakeHolderValueMap","Requirement","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."StakeHolderValueMap_Requirement"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "StakeHolderValueMap","Requirement","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."StakeHolderValueMap_Requirement_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
CREATE OR REPLACE FUNCTION "Iteration_REPLACE"."StakeHolderValueMap_Category_Data" ()
    RETURNS SETOF "Iteration_REPLACE"."StakeHolderValueMap_Category" AS
$BODY$
DECLARE
   instant timestamp;
BEGIN
   instant := "SiteDirectory".get_session_instant();

IF instant = 'infinity' THEN
   RETURN QUERY
   SELECT *
   FROM "Iteration_REPLACE"."StakeHolderValueMap_Category";
ELSE
   RETURN QUERY
   SELECT *
   FROM (SELECT "StakeHolderValueMap","Category","ValidFrom","ValidTo" 
      FROM "Iteration_REPLACE"."StakeHolderValueMap_Category"
      -- prefilter union candidates
      WHERE "ValidFrom" < instant
      AND "ValidTo" >= instant
       UNION ALL
      SELECT "StakeHolderValueMap","Category","ValidFrom","ValidTo"
      FROM "Iteration_REPLACE"."StakeHolderValueMap_Category_Audit"
      -- prefilter union candidates
      WHERE "Action" <> 'I'
      AND "ValidFrom" < instant
      AND "ValidTo" >= instant) "VersionedData"
   ORDER BY "VersionedData"."ValidTo" DESC;
END IF;

END
$BODY$
  LANGUAGE plpgsql VOLATILE;

CREATE VIEW "EngineeringModel_REPLACE"."Thing_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" AS "ValueTypeSet",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."TopContainer_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "TopContainer"."ValueTypeDictionary" AS "ValueTypeSet",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."TopContainer_Data"() AS "TopContainer" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."EngineeringModel_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "TopContainer"."ValueTypeDictionary" || "EngineeringModel"."ValueTypeDictionary" AS "ValueTypeSet",
	"EngineeringModel"."EngineeringModelSetup",
	COALESCE("EngineeringModel_CommonFileStore"."CommonFileStore",'{}'::text[]) AS "CommonFileStore",
	COALESCE("EngineeringModel_LogEntry"."LogEntry",'{}'::text[]) AS "LogEntry",
	COALESCE("EngineeringModel_Iteration"."Iteration",'{}'::text[]) AS "Iteration",
	COALESCE("EngineeringModel_Book"."Book",'{}'::text[]) AS "Book",
	COALESCE("EngineeringModel_GenericNote"."GenericNote",'{}'::text[]) AS "GenericNote",
	COALESCE("EngineeringModel_ModellingAnnotation"."ModellingAnnotation",'{}'::text[]) AS "ModellingAnnotation",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."TopContainer_Data"() AS "TopContainer" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModel_Data"() AS "EngineeringModel" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "CommonFileStore"."Container" AS "Iid", array_agg("CommonFileStore"."Iid"::text) AS "CommonFileStore"
   FROM "EngineeringModel_REPLACE"."CommonFileStore_Data"() AS "CommonFileStore"
   JOIN "EngineeringModel_REPLACE"."EngineeringModel_Data"() AS "EngineeringModel" ON "CommonFileStore"."Container" = "EngineeringModel"."Iid"
   GROUP BY "CommonFileStore"."Container") AS "EngineeringModel_CommonFileStore" USING ("Iid")
  LEFT JOIN (SELECT "ModelLogEntry"."Container" AS "Iid", array_agg("ModelLogEntry"."Iid"::text) AS "LogEntry"
   FROM "EngineeringModel_REPLACE"."ModelLogEntry_Data"() AS "ModelLogEntry"
   JOIN "EngineeringModel_REPLACE"."EngineeringModel_Data"() AS "EngineeringModel" ON "ModelLogEntry"."Container" = "EngineeringModel"."Iid"
   GROUP BY "ModelLogEntry"."Container") AS "EngineeringModel_LogEntry" USING ("Iid")
  LEFT JOIN (SELECT "Iteration"."Container" AS "Iid", array_agg("Iteration"."Iid"::text) AS "Iteration"
   FROM "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration"
   JOIN "EngineeringModel_REPLACE"."EngineeringModel_Data"() AS "EngineeringModel" ON "Iteration"."Container" = "EngineeringModel"."Iid"
   GROUP BY "Iteration"."Container") AS "EngineeringModel_Iteration" USING ("Iid")
  LEFT JOIN (SELECT "Book"."Container" AS "Iid", ARRAY[array_agg("Book"."Sequence"::text), array_agg("Book"."Iid"::text)] AS "Book"
   FROM "EngineeringModel_REPLACE"."Book_Data"() AS "Book"
   JOIN "EngineeringModel_REPLACE"."EngineeringModel_Data"() AS "EngineeringModel" ON "Book"."Container" = "EngineeringModel"."Iid"
   GROUP BY "Book"."Container") AS "EngineeringModel_Book" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataNote"."Container" AS "Iid", array_agg("EngineeringModelDataNote"."Iid"::text) AS "GenericNote"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataNote_Data"() AS "EngineeringModelDataNote"
   JOIN "EngineeringModel_REPLACE"."EngineeringModel_Data"() AS "EngineeringModel" ON "EngineeringModelDataNote"."Container" = "EngineeringModel"."Iid"
   GROUP BY "EngineeringModelDataNote"."Container") AS "EngineeringModel_GenericNote" USING ("Iid")
  LEFT JOIN (SELECT "ModellingAnnotationItem"."Container" AS "Iid", array_agg("ModellingAnnotationItem"."Iid"::text) AS "ModellingAnnotation"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModel_Data"() AS "EngineeringModel" ON "ModellingAnnotationItem"."Container" = "EngineeringModel"."Iid"
   GROUP BY "ModellingAnnotationItem"."Container") AS "EngineeringModel_ModellingAnnotation" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."FileStore_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "FileStore"."ValueTypeDictionary" AS "ValueTypeSet",
	"FileStore"."Owner",
	COALESCE("FileStore_Folder"."Folder",'{}'::text[]) AS "Folder",
	COALESCE("FileStore_File"."File",'{}'::text[]) AS "File",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."FileStore_Data"() AS "FileStore" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Folder"."Container" AS "Iid", array_agg("Folder"."Iid"::text) AS "Folder"
   FROM "EngineeringModel_REPLACE"."Folder_Data"() AS "Folder"
   JOIN "EngineeringModel_REPLACE"."FileStore_Data"() AS "FileStore" ON "Folder"."Container" = "FileStore"."Iid"
   GROUP BY "Folder"."Container") AS "FileStore_Folder" USING ("Iid")
  LEFT JOIN (SELECT "File"."Container" AS "Iid", array_agg("File"."Iid"::text) AS "File"
   FROM "EngineeringModel_REPLACE"."File_Data"() AS "File"
   JOIN "EngineeringModel_REPLACE"."FileStore_Data"() AS "FileStore" ON "File"."Container" = "FileStore"."Iid"
   GROUP BY "File"."Container") AS "FileStore_File" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."CommonFileStore_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "FileStore"."ValueTypeDictionary" || "CommonFileStore"."ValueTypeDictionary" AS "ValueTypeSet",
	"CommonFileStore"."Container",
	NULL::bigint AS "Sequence",
	"FileStore"."Owner",
	COALESCE("FileStore_Folder"."Folder",'{}'::text[]) AS "Folder",
	COALESCE("FileStore_File"."File",'{}'::text[]) AS "File",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."FileStore_Data"() AS "FileStore" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."CommonFileStore_Data"() AS "CommonFileStore" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Folder"."Container" AS "Iid", array_agg("Folder"."Iid"::text) AS "Folder"
   FROM "EngineeringModel_REPLACE"."Folder_Data"() AS "Folder"
   JOIN "EngineeringModel_REPLACE"."FileStore_Data"() AS "FileStore" ON "Folder"."Container" = "FileStore"."Iid"
   GROUP BY "Folder"."Container") AS "FileStore_Folder" USING ("Iid")
  LEFT JOIN (SELECT "File"."Container" AS "Iid", array_agg("File"."Iid"::text) AS "File"
   FROM "EngineeringModel_REPLACE"."File_Data"() AS "File"
   JOIN "EngineeringModel_REPLACE"."FileStore_Data"() AS "FileStore" ON "File"."Container" = "FileStore"."Iid"
   GROUP BY "File"."Container") AS "FileStore_File" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."Folder_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Folder"."ValueTypeDictionary" AS "ValueTypeSet",
	"Folder"."Container",
	NULL::bigint AS "Sequence",
	"Folder"."Creator",
	"Folder"."ContainingFolder",
	"Folder"."Owner",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."Folder_Data"() AS "Folder" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."File_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "File"."ValueTypeDictionary" AS "ValueTypeSet",
	"File"."Container",
	NULL::bigint AS "Sequence",
	"File"."LockedBy",
	"File"."Owner",
	COALESCE("File_FileRevision"."FileRevision",'{}'::text[]) AS "FileRevision",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("File_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."File_Data"() AS "File" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "File" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."File_Category_Data"() AS "File_Category"
   JOIN "EngineeringModel_REPLACE"."File_Data"() AS "File" ON "File" = "Iid"
   GROUP BY "File") AS "File_Category" USING ("Iid")
  LEFT JOIN (SELECT "FileRevision"."Container" AS "Iid", array_agg("FileRevision"."Iid"::text) AS "FileRevision"
   FROM "EngineeringModel_REPLACE"."FileRevision_Data"() AS "FileRevision"
   JOIN "EngineeringModel_REPLACE"."File_Data"() AS "File" ON "FileRevision"."Container" = "File"."Iid"
   GROUP BY "FileRevision"."Container") AS "File_FileRevision" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."FileRevision_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "FileRevision"."ValueTypeDictionary" AS "ValueTypeSet",
	"FileRevision"."Container",
	NULL::bigint AS "Sequence",
	"FileRevision"."Creator",
	"FileRevision"."ContainingFolder",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("FileRevision_FileType"."FileType",'{}'::text[]) AS "FileType"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."FileRevision_Data"() AS "FileRevision" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "FileRevision" AS "Iid", ARRAY[array_agg("Sequence"::text), array_agg("FileType"::text)] AS "FileType"
   FROM "EngineeringModel_REPLACE"."FileRevision_FileType_Data"() AS "FileRevision_FileType"
   JOIN "EngineeringModel_REPLACE"."FileRevision_Data"() AS "FileRevision" ON "FileRevision" = "Iid"
   GROUP BY "FileRevision") AS "FileRevision_FileType" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."ModelLogEntry_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ModelLogEntry"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModelLogEntry"."Container",
	NULL::bigint AS "Sequence",
	"ModelLogEntry"."Author",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ModelLogEntry_Category"."Category",'{}'::text[]) AS "Category",
	COALESCE("ModelLogEntry_AffectedItemIid"."AffectedItemIid",'{}'::text[]) AS "AffectedItemIid"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."ModelLogEntry_Data"() AS "ModelLogEntry" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ModelLogEntry" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."ModelLogEntry_Category_Data"() AS "ModelLogEntry_Category"
   JOIN "EngineeringModel_REPLACE"."ModelLogEntry_Data"() AS "ModelLogEntry" ON "ModelLogEntry" = "Iid"
   GROUP BY "ModelLogEntry") AS "ModelLogEntry_Category" USING ("Iid")
 LEFT JOIN (SELECT "ModelLogEntry" AS "Iid", array_agg("AffectedItemIid"::text) AS "AffectedItemIid"
   FROM "EngineeringModel_REPLACE"."ModelLogEntry_AffectedItemIid_Data"() AS "ModelLogEntry_AffectedItemIid"
   JOIN "EngineeringModel_REPLACE"."ModelLogEntry_Data"() AS "ModelLogEntry" ON "ModelLogEntry" = "Iid"
   GROUP BY "ModelLogEntry") AS "ModelLogEntry_AffectedItemIid" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."Iteration_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Iteration"."ValueTypeDictionary" AS "ValueTypeSet",
	"Iteration"."Container",
	NULL::bigint AS "Sequence",
	"Iteration"."IterationSetup",
	"Iteration"."TopElement",
	"Iteration"."DefaultOption",
	COALESCE("Iteration_Option"."Option",'{}'::text[]) AS "Option",
	COALESCE("Iteration_Publication"."Publication",'{}'::text[]) AS "Publication",
	COALESCE("Iteration_PossibleFiniteStateList"."PossibleFiniteStateList",'{}'::text[]) AS "PossibleFiniteStateList",
	COALESCE("Iteration_Element"."Element",'{}'::text[]) AS "Element",
	COALESCE("Iteration_Relationship"."Relationship",'{}'::text[]) AS "Relationship",
	COALESCE("Iteration_ExternalIdentifierMap"."ExternalIdentifierMap",'{}'::text[]) AS "ExternalIdentifierMap",
	COALESCE("Iteration_RequirementsSpecification"."RequirementsSpecification",'{}'::text[]) AS "RequirementsSpecification",
	COALESCE("Iteration_DomainFileStore"."DomainFileStore",'{}'::text[]) AS "DomainFileStore",
	COALESCE("Iteration_ActualFiniteStateList"."ActualFiniteStateList",'{}'::text[]) AS "ActualFiniteStateList",
	COALESCE("Iteration_RuleVerificationList"."RuleVerificationList",'{}'::text[]) AS "RuleVerificationList",
	COALESCE("Iteration_Stakeholder"."Stakeholder",'{}'::text[]) AS "Stakeholder",
	COALESCE("Iteration_Goal"."Goal",'{}'::text[]) AS "Goal",
	COALESCE("Iteration_ValueGroup"."ValueGroup",'{}'::text[]) AS "ValueGroup",
	COALESCE("Iteration_StakeholderValue"."StakeholderValue",'{}'::text[]) AS "StakeholderValue",
	COALESCE("Iteration_StakeholderValueMap"."StakeholderValueMap",'{}'::text[]) AS "StakeholderValueMap",
	COALESCE("Iteration_SharedDiagramStyle"."SharedDiagramStyle",'{}'::text[]) AS "SharedDiagramStyle",
	COALESCE("Iteration_DiagramCanvas"."DiagramCanvas",'{}'::text[]) AS "DiagramCanvas",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Option"."Container" AS "Iid", ARRAY[array_agg("Option"."Sequence"::text), array_agg("Option"."Iid"::text)] AS "Option"
   FROM "Iteration_REPLACE"."Option_Data"() AS "Option"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "Option"."Container" = "Iteration"."Iid"
   GROUP BY "Option"."Container") AS "Iteration_Option" USING ("Iid")
  LEFT JOIN (SELECT "Publication"."Container" AS "Iid", array_agg("Publication"."Iid"::text) AS "Publication"
   FROM "Iteration_REPLACE"."Publication_Data"() AS "Publication"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "Publication"."Container" = "Iteration"."Iid"
   GROUP BY "Publication"."Container") AS "Iteration_Publication" USING ("Iid")
  LEFT JOIN (SELECT "PossibleFiniteStateList"."Container" AS "Iid", array_agg("PossibleFiniteStateList"."Iid"::text) AS "PossibleFiniteStateList"
   FROM "Iteration_REPLACE"."PossibleFiniteStateList_Data"() AS "PossibleFiniteStateList"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "PossibleFiniteStateList"."Container" = "Iteration"."Iid"
   GROUP BY "PossibleFiniteStateList"."Container") AS "Iteration_PossibleFiniteStateList" USING ("Iid")
  LEFT JOIN (SELECT "ElementDefinition"."Container" AS "Iid", array_agg("ElementDefinition"."Iid"::text) AS "Element"
   FROM "Iteration_REPLACE"."ElementDefinition_Data"() AS "ElementDefinition"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "ElementDefinition"."Container" = "Iteration"."Iid"
   GROUP BY "ElementDefinition"."Container") AS "Iteration_Element" USING ("Iid")
  LEFT JOIN (SELECT "Relationship"."Container" AS "Iid", array_agg("Relationship"."Iid"::text) AS "Relationship"
   FROM "Iteration_REPLACE"."Relationship_Data"() AS "Relationship"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "Relationship"."Container" = "Iteration"."Iid"
   GROUP BY "Relationship"."Container") AS "Iteration_Relationship" USING ("Iid")
  LEFT JOIN (SELECT "ExternalIdentifierMap"."Container" AS "Iid", array_agg("ExternalIdentifierMap"."Iid"::text) AS "ExternalIdentifierMap"
   FROM "Iteration_REPLACE"."ExternalIdentifierMap_Data"() AS "ExternalIdentifierMap"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "ExternalIdentifierMap"."Container" = "Iteration"."Iid"
   GROUP BY "ExternalIdentifierMap"."Container") AS "Iteration_ExternalIdentifierMap" USING ("Iid")
  LEFT JOIN (SELECT "RequirementsSpecification"."Container" AS "Iid", array_agg("RequirementsSpecification"."Iid"::text) AS "RequirementsSpecification"
   FROM "Iteration_REPLACE"."RequirementsSpecification_Data"() AS "RequirementsSpecification"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "RequirementsSpecification"."Container" = "Iteration"."Iid"
   GROUP BY "RequirementsSpecification"."Container") AS "Iteration_RequirementsSpecification" USING ("Iid")
  LEFT JOIN (SELECT "DomainFileStore"."Container" AS "Iid", array_agg("DomainFileStore"."Iid"::text) AS "DomainFileStore"
   FROM "Iteration_REPLACE"."DomainFileStore_Data"() AS "DomainFileStore"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "DomainFileStore"."Container" = "Iteration"."Iid"
   GROUP BY "DomainFileStore"."Container") AS "Iteration_DomainFileStore" USING ("Iid")
  LEFT JOIN (SELECT "ActualFiniteStateList"."Container" AS "Iid", array_agg("ActualFiniteStateList"."Iid"::text) AS "ActualFiniteStateList"
   FROM "Iteration_REPLACE"."ActualFiniteStateList_Data"() AS "ActualFiniteStateList"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "ActualFiniteStateList"."Container" = "Iteration"."Iid"
   GROUP BY "ActualFiniteStateList"."Container") AS "Iteration_ActualFiniteStateList" USING ("Iid")
  LEFT JOIN (SELECT "RuleVerificationList"."Container" AS "Iid", array_agg("RuleVerificationList"."Iid"::text) AS "RuleVerificationList"
   FROM "Iteration_REPLACE"."RuleVerificationList_Data"() AS "RuleVerificationList"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "RuleVerificationList"."Container" = "Iteration"."Iid"
   GROUP BY "RuleVerificationList"."Container") AS "Iteration_RuleVerificationList" USING ("Iid")
  LEFT JOIN (SELECT "Stakeholder"."Container" AS "Iid", array_agg("Stakeholder"."Iid"::text) AS "Stakeholder"
   FROM "Iteration_REPLACE"."Stakeholder_Data"() AS "Stakeholder"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "Stakeholder"."Container" = "Iteration"."Iid"
   GROUP BY "Stakeholder"."Container") AS "Iteration_Stakeholder" USING ("Iid")
  LEFT JOIN (SELECT "Goal"."Container" AS "Iid", array_agg("Goal"."Iid"::text) AS "Goal"
   FROM "Iteration_REPLACE"."Goal_Data"() AS "Goal"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "Goal"."Container" = "Iteration"."Iid"
   GROUP BY "Goal"."Container") AS "Iteration_Goal" USING ("Iid")
  LEFT JOIN (SELECT "ValueGroup"."Container" AS "Iid", array_agg("ValueGroup"."Iid"::text) AS "ValueGroup"
   FROM "Iteration_REPLACE"."ValueGroup_Data"() AS "ValueGroup"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "ValueGroup"."Container" = "Iteration"."Iid"
   GROUP BY "ValueGroup"."Container") AS "Iteration_ValueGroup" USING ("Iid")
  LEFT JOIN (SELECT "StakeholderValue"."Container" AS "Iid", array_agg("StakeholderValue"."Iid"::text) AS "StakeholderValue"
   FROM "Iteration_REPLACE"."StakeholderValue_Data"() AS "StakeholderValue"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "StakeholderValue"."Container" = "Iteration"."Iid"
   GROUP BY "StakeholderValue"."Container") AS "Iteration_StakeholderValue" USING ("Iid")
  LEFT JOIN (SELECT "StakeHolderValueMap"."Container" AS "Iid", array_agg("StakeHolderValueMap"."Iid"::text) AS "StakeholderValueMap"
   FROM "Iteration_REPLACE"."StakeHolderValueMap_Data"() AS "StakeHolderValueMap"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "StakeHolderValueMap"."Container" = "Iteration"."Iid"
   GROUP BY "StakeHolderValueMap"."Container") AS "Iteration_StakeholderValueMap" USING ("Iid")
  LEFT JOIN (SELECT "SharedStyle"."Container" AS "Iid", array_agg("SharedStyle"."Iid"::text) AS "SharedDiagramStyle"
   FROM "Iteration_REPLACE"."SharedStyle_Data"() AS "SharedStyle"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "SharedStyle"."Container" = "Iteration"."Iid"
   GROUP BY "SharedStyle"."Container") AS "Iteration_SharedDiagramStyle" USING ("Iid")
  LEFT JOIN (SELECT "DiagramCanvas"."Container" AS "Iid", array_agg("DiagramCanvas"."Iid"::text) AS "DiagramCanvas"
   FROM "Iteration_REPLACE"."DiagramCanvas_Data"() AS "DiagramCanvas"
   JOIN "EngineeringModel_REPLACE"."Iteration_Data"() AS "Iteration" ON "DiagramCanvas"."Container" = "Iteration"."Iid"
   GROUP BY "DiagramCanvas"."Container") AS "Iteration_DiagramCanvas" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."Book_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Book"."ValueTypeDictionary" AS "ValueTypeSet",
	"Book"."Container",
	"Book"."Sequence",
	"Book"."Owner",
	COALESCE("Book_Section"."Section",'{}'::text[]) AS "Section",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Book_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."Book_Data"() AS "Book" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Book" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."Book_Category_Data"() AS "Book_Category"
   JOIN "EngineeringModel_REPLACE"."Book_Data"() AS "Book" ON "Book" = "Iid"
   GROUP BY "Book") AS "Book_Category" USING ("Iid")
  LEFT JOIN (SELECT "Section"."Container" AS "Iid", ARRAY[array_agg("Section"."Sequence"::text), array_agg("Section"."Iid"::text)] AS "Section"
   FROM "EngineeringModel_REPLACE"."Section_Data"() AS "Section"
   JOIN "EngineeringModel_REPLACE"."Book_Data"() AS "Book" ON "Section"."Container" = "Book"."Iid"
   GROUP BY "Section"."Container") AS "Book_Section" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."Section_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Section"."ValueTypeDictionary" AS "ValueTypeSet",
	"Section"."Container",
	"Section"."Sequence",
	"Section"."Owner",
	COALESCE("Section_Page"."Page",'{}'::text[]) AS "Page",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Section_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."Section_Data"() AS "Section" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Section" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."Section_Category_Data"() AS "Section_Category"
   JOIN "EngineeringModel_REPLACE"."Section_Data"() AS "Section" ON "Section" = "Iid"
   GROUP BY "Section") AS "Section_Category" USING ("Iid")
  LEFT JOIN (SELECT "Page"."Container" AS "Iid", ARRAY[array_agg("Page"."Sequence"::text), array_agg("Page"."Iid"::text)] AS "Page"
   FROM "EngineeringModel_REPLACE"."Page_Data"() AS "Page"
   JOIN "EngineeringModel_REPLACE"."Section_Data"() AS "Section" ON "Page"."Container" = "Section"."Iid"
   GROUP BY "Page"."Container") AS "Section_Page" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."Page_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Page"."ValueTypeDictionary" AS "ValueTypeSet",
	"Page"."Container",
	"Page"."Sequence",
	"Page"."Owner",
	COALESCE("Page_Note"."Note",'{}'::text[]) AS "Note",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Page_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."Page_Data"() AS "Page" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Page" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."Page_Category_Data"() AS "Page_Category"
   JOIN "EngineeringModel_REPLACE"."Page_Data"() AS "Page" ON "Page" = "Iid"
   GROUP BY "Page") AS "Page_Category" USING ("Iid")
  LEFT JOIN (SELECT "Note"."Container" AS "Iid", ARRAY[array_agg("Note"."Sequence"::text), array_agg("Note"."Iid"::text)] AS "Note"
   FROM "EngineeringModel_REPLACE"."Note_Data"() AS "Note"
   JOIN "EngineeringModel_REPLACE"."Page_Data"() AS "Page" ON "Note"."Container" = "Page"."Iid"
   GROUP BY "Note"."Container") AS "Page_Note" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."Note_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Note"."ValueTypeDictionary" AS "ValueTypeSet",
	"Note"."Container",
	"Note"."Sequence",
	"Note"."Owner",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Note_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."Note_Data"() AS "Note" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Note" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."Note_Category_Data"() AS "Note_Category"
   JOIN "EngineeringModel_REPLACE"."Note_Data"() AS "Note" ON "Note" = "Iid"
   GROUP BY "Note") AS "Note_Category" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."BinaryNote_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Note"."ValueTypeDictionary" || "BinaryNote"."ValueTypeDictionary" AS "ValueTypeSet",
	"Note"."Container",
	"Note"."Sequence",
	"Note"."Owner",
	"BinaryNote"."FileType",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Note_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."Note_Data"() AS "Note" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."BinaryNote_Data"() AS "BinaryNote" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Note" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."Note_Category_Data"() AS "Note_Category"
   JOIN "EngineeringModel_REPLACE"."Note_Data"() AS "Note" ON "Note" = "Iid"
   GROUP BY "Note") AS "Note_Category" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."TextualNote_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Note"."ValueTypeDictionary" || "TextualNote"."ValueTypeDictionary" AS "ValueTypeSet",
	"Note"."Container",
	"Note"."Sequence",
	"Note"."Owner",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Note_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."Note_Data"() AS "Note" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."TextualNote_Data"() AS "TextualNote" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Note" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."Note_Category_Data"() AS "Note_Category"
   JOIN "EngineeringModel_REPLACE"."Note_Data"() AS "Note" ON "Note" = "Iid"
   GROUP BY "Note") AS "Note_Category" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."GenericAnnotation_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" AS "ValueTypeSet",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" AS "ValueTypeSet",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."EngineeringModelDataNote_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" || "EngineeringModelDataNote"."ValueTypeDictionary" AS "ValueTypeSet",
	"EngineeringModelDataNote"."Container",
	NULL::bigint AS "Sequence",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataNote_Data"() AS "EngineeringModelDataNote" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."ThingReference_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ThingReference"."ValueTypeDictionary" AS "ValueTypeSet",
	"ThingReference"."ReferencedThing",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."ThingReference_Data"() AS "ThingReference" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."ModellingThingReference_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ThingReference"."ValueTypeDictionary" || "ModellingThingReference"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModellingThingReference"."Container",
	NULL::bigint AS "Sequence",
	"ThingReference"."ReferencedThing",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."ThingReference_Data"() AS "ThingReference" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."DiscussionItem_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "DiscussionItem"."ValueTypeDictionary" AS "ValueTypeSet",
	"DiscussionItem"."ReplyTo",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."DiscussionItem_Data"() AS "DiscussionItem" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "DiscussionItem"."ValueTypeDictionary" || "EngineeringModelDataDiscussionItem"."ValueTypeDictionary" AS "ValueTypeSet",
	"EngineeringModelDataDiscussionItem"."Container",
	NULL::bigint AS "Sequence",
	"DiscussionItem"."ReplyTo",
	"EngineeringModelDataDiscussionItem"."Author",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."DiscussionItem_Data"() AS "DiscussionItem" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."ModellingAnnotationItem_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" || "ModellingAnnotationItem"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModellingAnnotationItem"."Container",
	NULL::bigint AS "Sequence",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	"ModellingAnnotationItem"."Owner",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("ModellingAnnotationItem_ApprovedBy"."ApprovedBy",'{}'::text[]) AS "ApprovedBy",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ModellingAnnotationItem_SourceAnnotation"."SourceAnnotation",'{}'::text[]) AS "SourceAnnotation",
	COALESCE("ModellingAnnotationItem_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("SourceAnnotation"::text) AS "SourceAnnotation"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Data"() AS "ModellingAnnotationItem_SourceAnnotation"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_SourceAnnotation" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Data"() AS "ModellingAnnotationItem_Category"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_Category" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid")
  LEFT JOIN (SELECT "Approval"."Container" AS "Iid", array_agg("Approval"."Iid"::text) AS "ApprovedBy"
   FROM "EngineeringModel_REPLACE"."Approval_Data"() AS "Approval"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "Approval"."Container" = "ModellingAnnotationItem"."Iid"
   GROUP BY "Approval"."Container") AS "ModellingAnnotationItem_ApprovedBy" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."ContractDeviation_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" || "ModellingAnnotationItem"."ValueTypeDictionary" || "ContractDeviation"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModellingAnnotationItem"."Container",
	NULL::bigint AS "Sequence",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	"ModellingAnnotationItem"."Owner",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("ModellingAnnotationItem_ApprovedBy"."ApprovedBy",'{}'::text[]) AS "ApprovedBy",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ModellingAnnotationItem_SourceAnnotation"."SourceAnnotation",'{}'::text[]) AS "SourceAnnotation",
	COALESCE("ModellingAnnotationItem_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ContractDeviation_Data"() AS "ContractDeviation" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("SourceAnnotation"::text) AS "SourceAnnotation"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Data"() AS "ModellingAnnotationItem_SourceAnnotation"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_SourceAnnotation" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Data"() AS "ModellingAnnotationItem_Category"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_Category" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid")
  LEFT JOIN (SELECT "Approval"."Container" AS "Iid", array_agg("Approval"."Iid"::text) AS "ApprovedBy"
   FROM "EngineeringModel_REPLACE"."Approval_Data"() AS "Approval"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "Approval"."Container" = "ModellingAnnotationItem"."Iid"
   GROUP BY "Approval"."Container") AS "ModellingAnnotationItem_ApprovedBy" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."RequestForWaiver_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" || "ModellingAnnotationItem"."ValueTypeDictionary" || "ContractDeviation"."ValueTypeDictionary" || "RequestForWaiver"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModellingAnnotationItem"."Container",
	NULL::bigint AS "Sequence",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	"ModellingAnnotationItem"."Owner",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("ModellingAnnotationItem_ApprovedBy"."ApprovedBy",'{}'::text[]) AS "ApprovedBy",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ModellingAnnotationItem_SourceAnnotation"."SourceAnnotation",'{}'::text[]) AS "SourceAnnotation",
	COALESCE("ModellingAnnotationItem_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ContractDeviation_Data"() AS "ContractDeviation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."RequestForWaiver_Data"() AS "RequestForWaiver" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("SourceAnnotation"::text) AS "SourceAnnotation"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Data"() AS "ModellingAnnotationItem_SourceAnnotation"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_SourceAnnotation" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Data"() AS "ModellingAnnotationItem_Category"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_Category" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid")
  LEFT JOIN (SELECT "Approval"."Container" AS "Iid", array_agg("Approval"."Iid"::text) AS "ApprovedBy"
   FROM "EngineeringModel_REPLACE"."Approval_Data"() AS "Approval"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "Approval"."Container" = "ModellingAnnotationItem"."Iid"
   GROUP BY "Approval"."Container") AS "ModellingAnnotationItem_ApprovedBy" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."Approval_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "Approval"."ValueTypeDictionary" AS "ValueTypeSet",
	"Approval"."Container",
	NULL::bigint AS "Sequence",
	"Approval"."Author",
	"Approval"."Owner",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."Approval_Data"() AS "Approval" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."RequestForDeviation_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" || "ModellingAnnotationItem"."ValueTypeDictionary" || "ContractDeviation"."ValueTypeDictionary" || "RequestForDeviation"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModellingAnnotationItem"."Container",
	NULL::bigint AS "Sequence",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	"ModellingAnnotationItem"."Owner",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("ModellingAnnotationItem_ApprovedBy"."ApprovedBy",'{}'::text[]) AS "ApprovedBy",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ModellingAnnotationItem_SourceAnnotation"."SourceAnnotation",'{}'::text[]) AS "SourceAnnotation",
	COALESCE("ModellingAnnotationItem_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ContractDeviation_Data"() AS "ContractDeviation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."RequestForDeviation_Data"() AS "RequestForDeviation" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("SourceAnnotation"::text) AS "SourceAnnotation"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Data"() AS "ModellingAnnotationItem_SourceAnnotation"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_SourceAnnotation" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Data"() AS "ModellingAnnotationItem_Category"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_Category" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid")
  LEFT JOIN (SELECT "Approval"."Container" AS "Iid", array_agg("Approval"."Iid"::text) AS "ApprovedBy"
   FROM "EngineeringModel_REPLACE"."Approval_Data"() AS "Approval"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "Approval"."Container" = "ModellingAnnotationItem"."Iid"
   GROUP BY "Approval"."Container") AS "ModellingAnnotationItem_ApprovedBy" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."ChangeRequest_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" || "ModellingAnnotationItem"."ValueTypeDictionary" || "ContractDeviation"."ValueTypeDictionary" || "ChangeRequest"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModellingAnnotationItem"."Container",
	NULL::bigint AS "Sequence",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	"ModellingAnnotationItem"."Owner",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("ModellingAnnotationItem_ApprovedBy"."ApprovedBy",'{}'::text[]) AS "ApprovedBy",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ModellingAnnotationItem_SourceAnnotation"."SourceAnnotation",'{}'::text[]) AS "SourceAnnotation",
	COALESCE("ModellingAnnotationItem_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ContractDeviation_Data"() AS "ContractDeviation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ChangeRequest_Data"() AS "ChangeRequest" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("SourceAnnotation"::text) AS "SourceAnnotation"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Data"() AS "ModellingAnnotationItem_SourceAnnotation"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_SourceAnnotation" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Data"() AS "ModellingAnnotationItem_Category"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_Category" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid")
  LEFT JOIN (SELECT "Approval"."Container" AS "Iid", array_agg("Approval"."Iid"::text) AS "ApprovedBy"
   FROM "EngineeringModel_REPLACE"."Approval_Data"() AS "Approval"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "Approval"."Container" = "ModellingAnnotationItem"."Iid"
   GROUP BY "Approval"."Container") AS "ModellingAnnotationItem_ApprovedBy" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" || "ModellingAnnotationItem"."ValueTypeDictionary" || "ReviewItemDiscrepancy"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModellingAnnotationItem"."Container",
	NULL::bigint AS "Sequence",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	"ModellingAnnotationItem"."Owner",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("ModellingAnnotationItem_ApprovedBy"."ApprovedBy",'{}'::text[]) AS "ApprovedBy",
	COALESCE("ReviewItemDiscrepancy_Solution"."Solution",'{}'::text[]) AS "Solution",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ModellingAnnotationItem_SourceAnnotation"."SourceAnnotation",'{}'::text[]) AS "SourceAnnotation",
	COALESCE("ModellingAnnotationItem_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_Data"() AS "ReviewItemDiscrepancy" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("SourceAnnotation"::text) AS "SourceAnnotation"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Data"() AS "ModellingAnnotationItem_SourceAnnotation"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_SourceAnnotation" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Data"() AS "ModellingAnnotationItem_Category"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_Category" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid")
  LEFT JOIN (SELECT "Approval"."Container" AS "Iid", array_agg("Approval"."Iid"::text) AS "ApprovedBy"
   FROM "EngineeringModel_REPLACE"."Approval_Data"() AS "Approval"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "Approval"."Container" = "ModellingAnnotationItem"."Iid"
   GROUP BY "Approval"."Container") AS "ModellingAnnotationItem_ApprovedBy" USING ("Iid")
  LEFT JOIN (SELECT "Solution"."Container" AS "Iid", array_agg("Solution"."Iid"::text) AS "Solution"
   FROM "EngineeringModel_REPLACE"."Solution_Data"() AS "Solution"
   JOIN "EngineeringModel_REPLACE"."ReviewItemDiscrepancy_Data"() AS "ReviewItemDiscrepancy" ON "Solution"."Container" = "ReviewItemDiscrepancy"."Iid"
   GROUP BY "Solution"."Container") AS "ReviewItemDiscrepancy_Solution" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."Solution_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "Solution"."ValueTypeDictionary" AS "ValueTypeSet",
	"Solution"."Container",
	NULL::bigint AS "Sequence",
	"Solution"."Author",
	"Solution"."Owner",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."Solution_Data"() AS "Solution" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."ActionItem_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" || "ModellingAnnotationItem"."ValueTypeDictionary" || "ActionItem"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModellingAnnotationItem"."Container",
	NULL::bigint AS "Sequence",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	"ModellingAnnotationItem"."Owner",
	"ActionItem"."Actionee",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("ModellingAnnotationItem_ApprovedBy"."ApprovedBy",'{}'::text[]) AS "ApprovedBy",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ModellingAnnotationItem_SourceAnnotation"."SourceAnnotation",'{}'::text[]) AS "SourceAnnotation",
	COALESCE("ModellingAnnotationItem_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ActionItem_Data"() AS "ActionItem" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("SourceAnnotation"::text) AS "SourceAnnotation"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Data"() AS "ModellingAnnotationItem_SourceAnnotation"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_SourceAnnotation" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Data"() AS "ModellingAnnotationItem_Category"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_Category" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid")
  LEFT JOIN (SELECT "Approval"."Container" AS "Iid", array_agg("Approval"."Iid"::text) AS "ApprovedBy"
   FROM "EngineeringModel_REPLACE"."Approval_Data"() AS "Approval"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "Approval"."Container" = "ModellingAnnotationItem"."Iid"
   GROUP BY "Approval"."Container") AS "ModellingAnnotationItem_ApprovedBy" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."ChangeProposal_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" || "ModellingAnnotationItem"."ValueTypeDictionary" || "ChangeProposal"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModellingAnnotationItem"."Container",
	NULL::bigint AS "Sequence",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	"ModellingAnnotationItem"."Owner",
	"ChangeProposal"."ChangeRequest",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("ModellingAnnotationItem_ApprovedBy"."ApprovedBy",'{}'::text[]) AS "ApprovedBy",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ModellingAnnotationItem_SourceAnnotation"."SourceAnnotation",'{}'::text[]) AS "SourceAnnotation",
	COALESCE("ModellingAnnotationItem_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ChangeProposal_Data"() AS "ChangeProposal" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("SourceAnnotation"::text) AS "SourceAnnotation"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Data"() AS "ModellingAnnotationItem_SourceAnnotation"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_SourceAnnotation" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Data"() AS "ModellingAnnotationItem_Category"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_Category" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid")
  LEFT JOIN (SELECT "Approval"."Container" AS "Iid", array_agg("Approval"."Iid"::text) AS "ApprovedBy"
   FROM "EngineeringModel_REPLACE"."Approval_Data"() AS "Approval"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "Approval"."Container" = "ModellingAnnotationItem"."Iid"
   GROUP BY "Approval"."Container") AS "ModellingAnnotationItem_ApprovedBy" USING ("Iid");

CREATE VIEW "EngineeringModel_REPLACE"."ContractChangeNotice_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "GenericAnnotation"."ValueTypeDictionary" || "EngineeringModelDataAnnotation"."ValueTypeDictionary" || "ModellingAnnotationItem"."ValueTypeDictionary" || "ContractChangeNotice"."ValueTypeDictionary" AS "ValueTypeSet",
	"ModellingAnnotationItem"."Container",
	NULL::bigint AS "Sequence",
	"EngineeringModelDataAnnotation"."Author",
	"EngineeringModelDataAnnotation"."PrimaryAnnotatedThing",
	"ModellingAnnotationItem"."Owner",
	"ContractChangeNotice"."ChangeProposal",
	COALESCE("EngineeringModelDataAnnotation_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing",
	COALESCE("EngineeringModelDataAnnotation_Discussion"."Discussion",'{}'::text[]) AS "Discussion",
	COALESCE("ModellingAnnotationItem_ApprovedBy"."ApprovedBy",'{}'::text[]) AS "ApprovedBy",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ModellingAnnotationItem_SourceAnnotation"."SourceAnnotation",'{}'::text[]) AS "SourceAnnotation",
	COALESCE("ModellingAnnotationItem_Category"."Category",'{}'::text[]) AS "Category"
  FROM "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "EngineeringModel_REPLACE"."GenericAnnotation_Data"() AS "GenericAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" USING ("Iid")
  JOIN "EngineeringModel_REPLACE"."ContractChangeNotice_Data"() AS "ContractChangeNotice" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "EngineeringModel_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "EngineeringModel_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("SourceAnnotation"::text) AS "SourceAnnotation"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_SourceAnnotation_Data"() AS "ModellingAnnotationItem_SourceAnnotation"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_SourceAnnotation" USING ("Iid")
 LEFT JOIN (SELECT "ModellingAnnotationItem" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "EngineeringModel_REPLACE"."ModellingAnnotationItem_Category_Data"() AS "ModellingAnnotationItem_Category"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "ModellingAnnotationItem" = "Iid"
   GROUP BY "ModellingAnnotationItem") AS "ModellingAnnotationItem_Category" USING ("Iid")
  LEFT JOIN (SELECT "ModellingThingReference"."Container" AS "Iid", array_agg("ModellingThingReference"."Iid"::text) AS "RelatedThing"
   FROM "EngineeringModel_REPLACE"."ModellingThingReference_Data"() AS "ModellingThingReference"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "ModellingThingReference"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "ModellingThingReference"."Container") AS "EngineeringModelDataAnnotation_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "EngineeringModelDataDiscussionItem"."Container" AS "Iid", array_agg("EngineeringModelDataDiscussionItem"."Iid"::text) AS "Discussion"
   FROM "EngineeringModel_REPLACE"."EngineeringModelDataDiscussionItem_Data"() AS "EngineeringModelDataDiscussionItem"
   JOIN "EngineeringModel_REPLACE"."EngineeringModelDataAnnotation_Data"() AS "EngineeringModelDataAnnotation" ON "EngineeringModelDataDiscussionItem"."Container" = "EngineeringModelDataAnnotation"."Iid"
   GROUP BY "EngineeringModelDataDiscussionItem"."Container") AS "EngineeringModelDataAnnotation_Discussion" USING ("Iid")
  LEFT JOIN (SELECT "Approval"."Container" AS "Iid", array_agg("Approval"."Iid"::text) AS "ApprovedBy"
   FROM "EngineeringModel_REPLACE"."Approval_Data"() AS "Approval"
   JOIN "EngineeringModel_REPLACE"."ModellingAnnotationItem_Data"() AS "ModellingAnnotationItem" ON "Approval"."Container" = "ModellingAnnotationItem"."Iid"
   GROUP BY "Approval"."Container") AS "ModellingAnnotationItem_ApprovedBy" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Thing_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" AS "ValueTypeSet",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."DefinedThing_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" AS "ValueTypeSet",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Option_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "Option"."ValueTypeDictionary" AS "ValueTypeSet",
	"Option"."Container",
	"Option"."Sequence",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("Option_NestedElement"."NestedElement",'{}'::text[]) AS "NestedElement",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Option_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."Option_Data"() AS "Option" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Option" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."Option_Category_Data"() AS "Option_Category"
   JOIN "Iteration_REPLACE"."Option_Data"() AS "Option" ON "Option" = "Iid"
   GROUP BY "Option") AS "Option_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "NestedElement"."Container" AS "Iid", array_agg("NestedElement"."Iid"::text) AS "NestedElement"
   FROM "Iteration_REPLACE"."NestedElement_Data"() AS "NestedElement"
   JOIN "Iteration_REPLACE"."Option_Data"() AS "Option" ON "NestedElement"."Container" = "Option"."Iid"
   GROUP BY "NestedElement"."Container") AS "Option_NestedElement" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Alias_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Alias"."ValueTypeDictionary" AS "ValueTypeSet",
	"Alias"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."Alias_Data"() AS "Alias" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Definition_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Definition"."ValueTypeDictionary" AS "ValueTypeSet",
	"Definition"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Definition_Citation"."Citation",'{}'::text[]) AS "Citation",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Definition_Note"."Note",'{}'::text[]) AS "Note",
	COALESCE("Definition_Example"."Example",'{}'::text[]) AS "Example"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."Definition_Data"() AS "Definition" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Definition" AS "Iid", ARRAY[array_agg("Sequence"::text), array_agg("Note"::text)] AS "Note"
   FROM "Iteration_REPLACE"."Definition_Note_Data"() AS "Definition_Note"
   JOIN "Iteration_REPLACE"."Definition_Data"() AS "Definition" ON "Definition" = "Iid"
   GROUP BY "Definition") AS "Definition_Note" USING ("Iid")
 LEFT JOIN (SELECT "Definition" AS "Iid", ARRAY[array_agg("Sequence"::text), array_agg("Example"::text)] AS "Example"
   FROM "Iteration_REPLACE"."Definition_Example_Data"() AS "Definition_Example"
   JOIN "Iteration_REPLACE"."Definition_Data"() AS "Definition" ON "Definition" = "Iid"
   GROUP BY "Definition") AS "Definition_Example" USING ("Iid")
  LEFT JOIN (SELECT "Citation"."Container" AS "Iid", array_agg("Citation"."Iid"::text) AS "Citation"
   FROM "Iteration_REPLACE"."Citation_Data"() AS "Citation"
   JOIN "Iteration_REPLACE"."Definition_Data"() AS "Definition" ON "Citation"."Container" = "Definition"."Iid"
   GROUP BY "Citation"."Container") AS "Definition_Citation" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Citation_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Citation"."ValueTypeDictionary" AS "ValueTypeSet",
	"Citation"."Container",
	NULL::bigint AS "Sequence",
	"Citation"."Source",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."Citation_Data"() AS "Citation" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."HyperLink_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "HyperLink"."ValueTypeDictionary" AS "ValueTypeSet",
	"HyperLink"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."NestedElement_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "NestedElement"."ValueTypeDictionary" AS "ValueTypeSet",
	"NestedElement"."Container",
	NULL::bigint AS "Sequence",
	"NestedElement"."RootElement",
	COALESCE("NestedElement_NestedParameter"."NestedParameter",'{}'::text[]) AS "NestedParameter",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("NestedElement_ElementUsage"."ElementUsage",'{}'::text[]) AS "ElementUsage"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."NestedElement_Data"() AS "NestedElement" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "NestedElement" AS "Iid", ARRAY[array_agg("Sequence"::text), array_agg("ElementUsage"::text)] AS "ElementUsage"
   FROM "Iteration_REPLACE"."NestedElement_ElementUsage_Data"() AS "NestedElement_ElementUsage"
   JOIN "Iteration_REPLACE"."NestedElement_Data"() AS "NestedElement" ON "NestedElement" = "Iid"
   GROUP BY "NestedElement") AS "NestedElement_ElementUsage" USING ("Iid")
  LEFT JOIN (SELECT "NestedParameter"."Container" AS "Iid", array_agg("NestedParameter"."Iid"::text) AS "NestedParameter"
   FROM "Iteration_REPLACE"."NestedParameter_Data"() AS "NestedParameter"
   JOIN "Iteration_REPLACE"."NestedElement_Data"() AS "NestedElement" ON "NestedParameter"."Container" = "NestedElement"."Iid"
   GROUP BY "NestedParameter"."Container") AS "NestedElement_NestedParameter" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."NestedParameter_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "NestedParameter"."ValueTypeDictionary" AS "ValueTypeSet",
	"NestedParameter"."Container",
	NULL::bigint AS "Sequence",
	"NestedParameter"."AssociatedParameter",
	"NestedParameter"."ActualState",
	"NestedParameter"."Owner",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."NestedParameter_Data"() AS "NestedParameter" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Publication_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Publication"."ValueTypeDictionary" AS "ValueTypeSet",
	"Publication"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Publication_Domain"."Domain",'{}'::text[]) AS "Domain",
	COALESCE("Publication_PublishedParameter"."PublishedParameter",'{}'::text[]) AS "PublishedParameter"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."Publication_Data"() AS "Publication" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Publication" AS "Iid", array_agg("Domain"::text) AS "Domain"
   FROM "Iteration_REPLACE"."Publication_Domain_Data"() AS "Publication_Domain"
   JOIN "Iteration_REPLACE"."Publication_Data"() AS "Publication" ON "Publication" = "Iid"
   GROUP BY "Publication") AS "Publication_Domain" USING ("Iid")
 LEFT JOIN (SELECT "Publication" AS "Iid", array_agg("PublishedParameter"::text) AS "PublishedParameter"
   FROM "Iteration_REPLACE"."Publication_PublishedParameter_Data"() AS "Publication_PublishedParameter"
   JOIN "Iteration_REPLACE"."Publication_Data"() AS "Publication" ON "Publication" = "Iid"
   GROUP BY "Publication") AS "Publication_PublishedParameter" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."PossibleFiniteStateList_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "PossibleFiniteStateList"."ValueTypeDictionary" AS "ValueTypeSet",
	"PossibleFiniteStateList"."Container",
	NULL::bigint AS "Sequence",
	"PossibleFiniteStateList"."DefaultState",
	"PossibleFiniteStateList"."Owner",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("PossibleFiniteStateList_PossibleState"."PossibleState",'{}'::text[]) AS "PossibleState",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("PossibleFiniteStateList_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."PossibleFiniteStateList_Data"() AS "PossibleFiniteStateList" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "PossibleFiniteStateList" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."PossibleFiniteStateList_Category_Data"() AS "PossibleFiniteStateList_Category"
   JOIN "Iteration_REPLACE"."PossibleFiniteStateList_Data"() AS "PossibleFiniteStateList" ON "PossibleFiniteStateList" = "Iid"
   GROUP BY "PossibleFiniteStateList") AS "PossibleFiniteStateList_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "PossibleFiniteState"."Container" AS "Iid", ARRAY[array_agg("PossibleFiniteState"."Sequence"::text), array_agg("PossibleFiniteState"."Iid"::text)] AS "PossibleState"
   FROM "Iteration_REPLACE"."PossibleFiniteState_Data"() AS "PossibleFiniteState"
   JOIN "Iteration_REPLACE"."PossibleFiniteStateList_Data"() AS "PossibleFiniteStateList" ON "PossibleFiniteState"."Container" = "PossibleFiniteStateList"."Iid"
   GROUP BY "PossibleFiniteState"."Container") AS "PossibleFiniteStateList_PossibleState" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."PossibleFiniteState_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "PossibleFiniteState"."ValueTypeDictionary" AS "ValueTypeSet",
	"PossibleFiniteState"."Container",
	"PossibleFiniteState"."Sequence",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."PossibleFiniteState_Data"() AS "PossibleFiniteState" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ElementBase_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "ElementBase"."ValueTypeDictionary" AS "ValueTypeSet",
	"ElementBase"."Owner",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ElementBase_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."ElementBase_Data"() AS "ElementBase" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ElementBase" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."ElementBase_Category_Data"() AS "ElementBase_Category"
   JOIN "Iteration_REPLACE"."ElementBase_Data"() AS "ElementBase" ON "ElementBase" = "Iid"
   GROUP BY "ElementBase") AS "ElementBase_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ElementDefinition_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "ElementBase"."ValueTypeDictionary" || "ElementDefinition"."ValueTypeDictionary" AS "ValueTypeSet",
	"ElementDefinition"."Container",
	NULL::bigint AS "Sequence",
	"ElementBase"."Owner",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("ElementDefinition_ContainedElement"."ContainedElement",'{}'::text[]) AS "ContainedElement",
	COALESCE("ElementDefinition_Parameter"."Parameter",'{}'::text[]) AS "Parameter",
	COALESCE("ElementDefinition_ParameterGroup"."ParameterGroup",'{}'::text[]) AS "ParameterGroup",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ElementBase_Category"."Category",'{}'::text[]) AS "Category",
	COALESCE("ElementDefinition_ReferencedElement"."ReferencedElement",'{}'::text[]) AS "ReferencedElement"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."ElementBase_Data"() AS "ElementBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."ElementDefinition_Data"() AS "ElementDefinition" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ElementBase" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."ElementBase_Category_Data"() AS "ElementBase_Category"
   JOIN "Iteration_REPLACE"."ElementBase_Data"() AS "ElementBase" ON "ElementBase" = "Iid"
   GROUP BY "ElementBase") AS "ElementBase_Category" USING ("Iid")
 LEFT JOIN (SELECT "ElementDefinition" AS "Iid", array_agg("ReferencedElement"::text) AS "ReferencedElement"
   FROM "Iteration_REPLACE"."ElementDefinition_ReferencedElement_Data"() AS "ElementDefinition_ReferencedElement"
   JOIN "Iteration_REPLACE"."ElementDefinition_Data"() AS "ElementDefinition" ON "ElementDefinition" = "Iid"
   GROUP BY "ElementDefinition") AS "ElementDefinition_ReferencedElement" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "ElementUsage"."Container" AS "Iid", array_agg("ElementUsage"."Iid"::text) AS "ContainedElement"
   FROM "Iteration_REPLACE"."ElementUsage_Data"() AS "ElementUsage"
   JOIN "Iteration_REPLACE"."ElementDefinition_Data"() AS "ElementDefinition" ON "ElementUsage"."Container" = "ElementDefinition"."Iid"
   GROUP BY "ElementUsage"."Container") AS "ElementDefinition_ContainedElement" USING ("Iid")
  LEFT JOIN (SELECT "Parameter"."Container" AS "Iid", array_agg("Parameter"."Iid"::text) AS "Parameter"
   FROM "Iteration_REPLACE"."Parameter_Data"() AS "Parameter"
   JOIN "Iteration_REPLACE"."ElementDefinition_Data"() AS "ElementDefinition" ON "Parameter"."Container" = "ElementDefinition"."Iid"
   GROUP BY "Parameter"."Container") AS "ElementDefinition_Parameter" USING ("Iid")
  LEFT JOIN (SELECT "ParameterGroup"."Container" AS "Iid", array_agg("ParameterGroup"."Iid"::text) AS "ParameterGroup"
   FROM "Iteration_REPLACE"."ParameterGroup_Data"() AS "ParameterGroup"
   JOIN "Iteration_REPLACE"."ElementDefinition_Data"() AS "ElementDefinition" ON "ParameterGroup"."Container" = "ElementDefinition"."Iid"
   GROUP BY "ParameterGroup"."Container") AS "ElementDefinition_ParameterGroup" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ElementUsage_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "ElementBase"."ValueTypeDictionary" || "ElementUsage"."ValueTypeDictionary" AS "ValueTypeSet",
	"ElementUsage"."Container",
	NULL::bigint AS "Sequence",
	"ElementBase"."Owner",
	"ElementUsage"."ElementDefinition",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("ElementUsage_ParameterOverride"."ParameterOverride",'{}'::text[]) AS "ParameterOverride",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ElementBase_Category"."Category",'{}'::text[]) AS "Category",
	COALESCE("ElementUsage_ExcludeOption"."ExcludeOption",'{}'::text[]) AS "ExcludeOption"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."ElementBase_Data"() AS "ElementBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."ElementUsage_Data"() AS "ElementUsage" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ElementBase" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."ElementBase_Category_Data"() AS "ElementBase_Category"
   JOIN "Iteration_REPLACE"."ElementBase_Data"() AS "ElementBase" ON "ElementBase" = "Iid"
   GROUP BY "ElementBase") AS "ElementBase_Category" USING ("Iid")
 LEFT JOIN (SELECT "ElementUsage" AS "Iid", array_agg("ExcludeOption"::text) AS "ExcludeOption"
   FROM "Iteration_REPLACE"."ElementUsage_ExcludeOption_Data"() AS "ElementUsage_ExcludeOption"
   JOIN "Iteration_REPLACE"."ElementUsage_Data"() AS "ElementUsage" ON "ElementUsage" = "Iid"
   GROUP BY "ElementUsage") AS "ElementUsage_ExcludeOption" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "ParameterOverride"."Container" AS "Iid", array_agg("ParameterOverride"."Iid"::text) AS "ParameterOverride"
   FROM "Iteration_REPLACE"."ParameterOverride_Data"() AS "ParameterOverride"
   JOIN "Iteration_REPLACE"."ElementUsage_Data"() AS "ElementUsage" ON "ParameterOverride"."Container" = "ElementUsage"."Iid"
   GROUP BY "ParameterOverride"."Container") AS "ElementUsage_ParameterOverride" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParameterBase_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterBase"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParameterBase"."ParameterType",
	"ParameterBase"."Scale",
	"ParameterBase"."StateDependence",
	"ParameterBase"."Group",
	"ParameterBase"."Owner",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterBase_Data"() AS "ParameterBase" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParameterOrOverrideBase_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterBase"."ValueTypeDictionary" || "ParameterOrOverrideBase"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParameterBase"."ParameterType",
	"ParameterBase"."Scale",
	"ParameterBase"."StateDependence",
	"ParameterBase"."Group",
	"ParameterBase"."Owner",
	COALESCE("ParameterOrOverrideBase_ParameterSubscription"."ParameterSubscription",'{}'::text[]) AS "ParameterSubscription",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterBase_Data"() AS "ParameterBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."ParameterOrOverrideBase_Data"() AS "ParameterOrOverrideBase" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "ParameterSubscription"."Container" AS "Iid", array_agg("ParameterSubscription"."Iid"::text) AS "ParameterSubscription"
   FROM "Iteration_REPLACE"."ParameterSubscription_Data"() AS "ParameterSubscription"
   JOIN "Iteration_REPLACE"."ParameterOrOverrideBase_Data"() AS "ParameterOrOverrideBase" ON "ParameterSubscription"."Container" = "ParameterOrOverrideBase"."Iid"
   GROUP BY "ParameterSubscription"."Container") AS "ParameterOrOverrideBase_ParameterSubscription" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParameterOverride_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterBase"."ValueTypeDictionary" || "ParameterOrOverrideBase"."ValueTypeDictionary" || "ParameterOverride"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParameterOverride"."Container",
	NULL::bigint AS "Sequence",
	"ParameterBase"."Owner",
	"ParameterOverride"."Parameter",
	COALESCE("ParameterOrOverrideBase_ParameterSubscription"."ParameterSubscription",'{}'::text[]) AS "ParameterSubscription",
	COALESCE("ParameterOverride_ValueSet"."ValueSet",'{}'::text[]) AS "ValueSet",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterBase_Data"() AS "ParameterBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."ParameterOrOverrideBase_Data"() AS "ParameterOrOverrideBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."ParameterOverride_Data"() AS "ParameterOverride" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "ParameterSubscription"."Container" AS "Iid", array_agg("ParameterSubscription"."Iid"::text) AS "ParameterSubscription"
   FROM "Iteration_REPLACE"."ParameterSubscription_Data"() AS "ParameterSubscription"
   JOIN "Iteration_REPLACE"."ParameterOrOverrideBase_Data"() AS "ParameterOrOverrideBase" ON "ParameterSubscription"."Container" = "ParameterOrOverrideBase"."Iid"
   GROUP BY "ParameterSubscription"."Container") AS "ParameterOrOverrideBase_ParameterSubscription" USING ("Iid")
  LEFT JOIN (SELECT "ParameterOverrideValueSet"."Container" AS "Iid", array_agg("ParameterOverrideValueSet"."Iid"::text) AS "ValueSet"
   FROM "Iteration_REPLACE"."ParameterOverrideValueSet_Data"() AS "ParameterOverrideValueSet"
   JOIN "Iteration_REPLACE"."ParameterOverride_Data"() AS "ParameterOverride" ON "ParameterOverrideValueSet"."Container" = "ParameterOverride"."Iid"
   GROUP BY "ParameterOverrideValueSet"."Container") AS "ParameterOverride_ValueSet" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParameterSubscription_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterBase"."ValueTypeDictionary" || "ParameterSubscription"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParameterSubscription"."Container",
	NULL::bigint AS "Sequence",
	"ParameterBase"."Owner",
	COALESCE("ParameterSubscription_ValueSet"."ValueSet",'{}'::text[]) AS "ValueSet",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterBase_Data"() AS "ParameterBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."ParameterSubscription_Data"() AS "ParameterSubscription" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "ParameterSubscriptionValueSet"."Container" AS "Iid", array_agg("ParameterSubscriptionValueSet"."Iid"::text) AS "ValueSet"
   FROM "Iteration_REPLACE"."ParameterSubscriptionValueSet_Data"() AS "ParameterSubscriptionValueSet"
   JOIN "Iteration_REPLACE"."ParameterSubscription_Data"() AS "ParameterSubscription" ON "ParameterSubscriptionValueSet"."Container" = "ParameterSubscription"."Iid"
   GROUP BY "ParameterSubscriptionValueSet"."Container") AS "ParameterSubscription_ValueSet" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParameterSubscriptionValueSet_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterSubscriptionValueSet"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParameterSubscriptionValueSet"."Container",
	NULL::bigint AS "Sequence",
	"ParameterSubscriptionValueSet"."SubscribedValueSet",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterSubscriptionValueSet_Data"() AS "ParameterSubscriptionValueSet" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParameterValueSetBase_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterValueSetBase"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParameterValueSetBase"."ActualState",
	"ParameterValueSetBase"."ActualOption",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterValueSetBase_Data"() AS "ParameterValueSetBase" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParameterOverrideValueSet_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterValueSetBase"."ValueTypeDictionary" || "ParameterOverrideValueSet"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParameterOverrideValueSet"."Container",
	NULL::bigint AS "Sequence",
	"ParameterOverrideValueSet"."ParameterValueSet",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterValueSetBase_Data"() AS "ParameterValueSetBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."ParameterOverrideValueSet_Data"() AS "ParameterOverrideValueSet" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Parameter_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterBase"."ValueTypeDictionary" || "ParameterOrOverrideBase"."ValueTypeDictionary" || "Parameter"."ValueTypeDictionary" AS "ValueTypeSet",
	"Parameter"."Container",
	NULL::bigint AS "Sequence",
	"ParameterBase"."ParameterType",
	"ParameterBase"."Scale",
	"ParameterBase"."StateDependence",
	"ParameterBase"."Group",
	"ParameterBase"."Owner",
	"Parameter"."RequestedBy",
	COALESCE("ParameterOrOverrideBase_ParameterSubscription"."ParameterSubscription",'{}'::text[]) AS "ParameterSubscription",
	COALESCE("Parameter_ValueSet"."ValueSet",'{}'::text[]) AS "ValueSet",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterBase_Data"() AS "ParameterBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."ParameterOrOverrideBase_Data"() AS "ParameterOrOverrideBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."Parameter_Data"() AS "Parameter" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "ParameterSubscription"."Container" AS "Iid", array_agg("ParameterSubscription"."Iid"::text) AS "ParameterSubscription"
   FROM "Iteration_REPLACE"."ParameterSubscription_Data"() AS "ParameterSubscription"
   JOIN "Iteration_REPLACE"."ParameterOrOverrideBase_Data"() AS "ParameterOrOverrideBase" ON "ParameterSubscription"."Container" = "ParameterOrOverrideBase"."Iid"
   GROUP BY "ParameterSubscription"."Container") AS "ParameterOrOverrideBase_ParameterSubscription" USING ("Iid")
  LEFT JOIN (SELECT "ParameterValueSet"."Container" AS "Iid", array_agg("ParameterValueSet"."Iid"::text) AS "ValueSet"
   FROM "Iteration_REPLACE"."ParameterValueSet_Data"() AS "ParameterValueSet"
   JOIN "Iteration_REPLACE"."Parameter_Data"() AS "Parameter" ON "ParameterValueSet"."Container" = "Parameter"."Iid"
   GROUP BY "ParameterValueSet"."Container") AS "Parameter_ValueSet" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParameterValueSet_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterValueSetBase"."ValueTypeDictionary" || "ParameterValueSet"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParameterValueSet"."Container",
	NULL::bigint AS "Sequence",
	"ParameterValueSetBase"."ActualState",
	"ParameterValueSetBase"."ActualOption",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterValueSetBase_Data"() AS "ParameterValueSetBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."ParameterValueSet_Data"() AS "ParameterValueSet" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParameterGroup_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterGroup"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParameterGroup"."Container",
	NULL::bigint AS "Sequence",
	"ParameterGroup"."ContainingGroup",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterGroup_Data"() AS "ParameterGroup" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Relationship_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Relationship"."ValueTypeDictionary" AS "ValueTypeSet",
	"Relationship"."Container",
	NULL::bigint AS "Sequence",
	"Relationship"."Owner",
	COALESCE("Relationship_ParameterValue"."ParameterValue",'{}'::text[]) AS "ParameterValue",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Relationship_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."Relationship_Data"() AS "Relationship" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Relationship" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."Relationship_Category_Data"() AS "Relationship_Category"
   JOIN "Iteration_REPLACE"."Relationship_Data"() AS "Relationship" ON "Relationship" = "Iid"
   GROUP BY "Relationship") AS "Relationship_Category" USING ("Iid")
  LEFT JOIN (SELECT "RelationshipParameterValue"."Container" AS "Iid", array_agg("RelationshipParameterValue"."Iid"::text) AS "ParameterValue"
   FROM "Iteration_REPLACE"."RelationshipParameterValue_Data"() AS "RelationshipParameterValue"
   JOIN "Iteration_REPLACE"."Relationship_Data"() AS "Relationship" ON "RelationshipParameterValue"."Container" = "Relationship"."Iid"
   GROUP BY "RelationshipParameterValue"."Container") AS "Relationship_ParameterValue" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."MultiRelationship_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Relationship"."ValueTypeDictionary" || "MultiRelationship"."ValueTypeDictionary" AS "ValueTypeSet",
	"Relationship"."Container",
	NULL::bigint AS "Sequence",
	"Relationship"."Owner",
	COALESCE("Relationship_ParameterValue"."ParameterValue",'{}'::text[]) AS "ParameterValue",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Relationship_Category"."Category",'{}'::text[]) AS "Category",
	COALESCE("MultiRelationship_RelatedThing"."RelatedThing",'{}'::text[]) AS "RelatedThing"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."Relationship_Data"() AS "Relationship" USING ("Iid")
  JOIN "Iteration_REPLACE"."MultiRelationship_Data"() AS "MultiRelationship" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Relationship" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."Relationship_Category_Data"() AS "Relationship_Category"
   JOIN "Iteration_REPLACE"."Relationship_Data"() AS "Relationship" ON "Relationship" = "Iid"
   GROUP BY "Relationship") AS "Relationship_Category" USING ("Iid")
 LEFT JOIN (SELECT "MultiRelationship" AS "Iid", array_agg("RelatedThing"::text) AS "RelatedThing"
   FROM "Iteration_REPLACE"."MultiRelationship_RelatedThing_Data"() AS "MultiRelationship_RelatedThing"
   JOIN "Iteration_REPLACE"."MultiRelationship_Data"() AS "MultiRelationship" ON "MultiRelationship" = "Iid"
   GROUP BY "MultiRelationship") AS "MultiRelationship_RelatedThing" USING ("Iid")
  LEFT JOIN (SELECT "RelationshipParameterValue"."Container" AS "Iid", array_agg("RelationshipParameterValue"."Iid"::text) AS "ParameterValue"
   FROM "Iteration_REPLACE"."RelationshipParameterValue_Data"() AS "RelationshipParameterValue"
   JOIN "Iteration_REPLACE"."Relationship_Data"() AS "Relationship" ON "RelationshipParameterValue"."Container" = "Relationship"."Iid"
   GROUP BY "RelationshipParameterValue"."Container") AS "Relationship_ParameterValue" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParameterValue_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterValue"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParameterValue"."ParameterType",
	"ParameterValue"."Scale",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterValue_Data"() AS "ParameterValue" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."RelationshipParameterValue_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterValue"."ValueTypeDictionary" || "RelationshipParameterValue"."ValueTypeDictionary" AS "ValueTypeSet",
	"RelationshipParameterValue"."Container",
	NULL::bigint AS "Sequence",
	"ParameterValue"."ParameterType",
	"ParameterValue"."Scale",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterValue_Data"() AS "ParameterValue" USING ("Iid")
  JOIN "Iteration_REPLACE"."RelationshipParameterValue_Data"() AS "RelationshipParameterValue" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."BinaryRelationship_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Relationship"."ValueTypeDictionary" || "BinaryRelationship"."ValueTypeDictionary" AS "ValueTypeSet",
	"Relationship"."Container",
	NULL::bigint AS "Sequence",
	"Relationship"."Owner",
	"BinaryRelationship"."Source",
	"BinaryRelationship"."Target",
	COALESCE("Relationship_ParameterValue"."ParameterValue",'{}'::text[]) AS "ParameterValue",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Relationship_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."Relationship_Data"() AS "Relationship" USING ("Iid")
  JOIN "Iteration_REPLACE"."BinaryRelationship_Data"() AS "BinaryRelationship" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Relationship" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."Relationship_Category_Data"() AS "Relationship_Category"
   JOIN "Iteration_REPLACE"."Relationship_Data"() AS "Relationship" ON "Relationship" = "Iid"
   GROUP BY "Relationship") AS "Relationship_Category" USING ("Iid")
  LEFT JOIN (SELECT "RelationshipParameterValue"."Container" AS "Iid", array_agg("RelationshipParameterValue"."Iid"::text) AS "ParameterValue"
   FROM "Iteration_REPLACE"."RelationshipParameterValue_Data"() AS "RelationshipParameterValue"
   JOIN "Iteration_REPLACE"."Relationship_Data"() AS "Relationship" ON "RelationshipParameterValue"."Container" = "Relationship"."Iid"
   GROUP BY "RelationshipParameterValue"."Container") AS "Relationship_ParameterValue" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ExternalIdentifierMap_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ExternalIdentifierMap"."ValueTypeDictionary" AS "ValueTypeSet",
	"ExternalIdentifierMap"."Container",
	NULL::bigint AS "Sequence",
	"ExternalIdentifierMap"."ExternalFormat",
	"ExternalIdentifierMap"."Owner",
	COALESCE("ExternalIdentifierMap_Correspondence"."Correspondence",'{}'::text[]) AS "Correspondence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ExternalIdentifierMap_Data"() AS "ExternalIdentifierMap" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "IdCorrespondence"."Container" AS "Iid", array_agg("IdCorrespondence"."Iid"::text) AS "Correspondence"
   FROM "Iteration_REPLACE"."IdCorrespondence_Data"() AS "IdCorrespondence"
   JOIN "Iteration_REPLACE"."ExternalIdentifierMap_Data"() AS "ExternalIdentifierMap" ON "IdCorrespondence"."Container" = "ExternalIdentifierMap"."Iid"
   GROUP BY "IdCorrespondence"."Container") AS "ExternalIdentifierMap_Correspondence" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."IdCorrespondence_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "IdCorrespondence"."ValueTypeDictionary" AS "ValueTypeSet",
	"IdCorrespondence"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."IdCorrespondence_Data"() AS "IdCorrespondence" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."RequirementsContainer_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "RequirementsContainer"."ValueTypeDictionary" AS "ValueTypeSet",
	"RequirementsContainer"."Owner",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("RequirementsContainer_Group"."Group",'{}'::text[]) AS "Group",
	COALESCE("RequirementsContainer_ParameterValue"."ParameterValue",'{}'::text[]) AS "ParameterValue",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("RequirementsContainer_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "RequirementsContainer" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."RequirementsContainer_Category_Data"() AS "RequirementsContainer_Category"
   JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" ON "RequirementsContainer" = "Iid"
   GROUP BY "RequirementsContainer") AS "RequirementsContainer_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "RequirementsGroup"."Container" AS "Iid", array_agg("RequirementsGroup"."Iid"::text) AS "Group"
   FROM "Iteration_REPLACE"."RequirementsGroup_Data"() AS "RequirementsGroup"
   JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" ON "RequirementsGroup"."Container" = "RequirementsContainer"."Iid"
   GROUP BY "RequirementsGroup"."Container") AS "RequirementsContainer_Group" USING ("Iid")
  LEFT JOIN (SELECT "RequirementsContainerParameterValue"."Container" AS "Iid", array_agg("RequirementsContainerParameterValue"."Iid"::text) AS "ParameterValue"
   FROM "Iteration_REPLACE"."RequirementsContainerParameterValue_Data"() AS "RequirementsContainerParameterValue"
   JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" ON "RequirementsContainerParameterValue"."Container" = "RequirementsContainer"."Iid"
   GROUP BY "RequirementsContainerParameterValue"."Container") AS "RequirementsContainer_ParameterValue" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."RequirementsSpecification_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "RequirementsContainer"."ValueTypeDictionary" || "RequirementsSpecification"."ValueTypeDictionary" AS "ValueTypeSet",
	"RequirementsSpecification"."Container",
	NULL::bigint AS "Sequence",
	"RequirementsContainer"."Owner",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("RequirementsContainer_Group"."Group",'{}'::text[]) AS "Group",
	COALESCE("RequirementsContainer_ParameterValue"."ParameterValue",'{}'::text[]) AS "ParameterValue",
	COALESCE("RequirementsSpecification_Requirement"."Requirement",'{}'::text[]) AS "Requirement",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("RequirementsContainer_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" USING ("Iid")
  JOIN "Iteration_REPLACE"."RequirementsSpecification_Data"() AS "RequirementsSpecification" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "RequirementsContainer" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."RequirementsContainer_Category_Data"() AS "RequirementsContainer_Category"
   JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" ON "RequirementsContainer" = "Iid"
   GROUP BY "RequirementsContainer") AS "RequirementsContainer_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "RequirementsGroup"."Container" AS "Iid", array_agg("RequirementsGroup"."Iid"::text) AS "Group"
   FROM "Iteration_REPLACE"."RequirementsGroup_Data"() AS "RequirementsGroup"
   JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" ON "RequirementsGroup"."Container" = "RequirementsContainer"."Iid"
   GROUP BY "RequirementsGroup"."Container") AS "RequirementsContainer_Group" USING ("Iid")
  LEFT JOIN (SELECT "RequirementsContainerParameterValue"."Container" AS "Iid", array_agg("RequirementsContainerParameterValue"."Iid"::text) AS "ParameterValue"
   FROM "Iteration_REPLACE"."RequirementsContainerParameterValue_Data"() AS "RequirementsContainerParameterValue"
   JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" ON "RequirementsContainerParameterValue"."Container" = "RequirementsContainer"."Iid"
   GROUP BY "RequirementsContainerParameterValue"."Container") AS "RequirementsContainer_ParameterValue" USING ("Iid")
  LEFT JOIN (SELECT "Requirement"."Container" AS "Iid", array_agg("Requirement"."Iid"::text) AS "Requirement"
   FROM "Iteration_REPLACE"."Requirement_Data"() AS "Requirement"
   JOIN "Iteration_REPLACE"."RequirementsSpecification_Data"() AS "RequirementsSpecification" ON "Requirement"."Container" = "RequirementsSpecification"."Iid"
   GROUP BY "Requirement"."Container") AS "RequirementsSpecification_Requirement" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."RequirementsGroup_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "RequirementsContainer"."ValueTypeDictionary" || "RequirementsGroup"."ValueTypeDictionary" AS "ValueTypeSet",
	"RequirementsGroup"."Container",
	NULL::bigint AS "Sequence",
	"RequirementsContainer"."Owner",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("RequirementsContainer_Group"."Group",'{}'::text[]) AS "Group",
	COALESCE("RequirementsContainer_ParameterValue"."ParameterValue",'{}'::text[]) AS "ParameterValue",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("RequirementsContainer_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" USING ("Iid")
  JOIN "Iteration_REPLACE"."RequirementsGroup_Data"() AS "RequirementsGroup" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "RequirementsContainer" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."RequirementsContainer_Category_Data"() AS "RequirementsContainer_Category"
   JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" ON "RequirementsContainer" = "Iid"
   GROUP BY "RequirementsContainer") AS "RequirementsContainer_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "RequirementsGroup"."Container" AS "Iid", array_agg("RequirementsGroup"."Iid"::text) AS "Group"
   FROM "Iteration_REPLACE"."RequirementsGroup_Data"() AS "RequirementsGroup"
   JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" ON "RequirementsGroup"."Container" = "RequirementsContainer"."Iid"
   GROUP BY "RequirementsGroup"."Container") AS "RequirementsContainer_Group" USING ("Iid")
  LEFT JOIN (SELECT "RequirementsContainerParameterValue"."Container" AS "Iid", array_agg("RequirementsContainerParameterValue"."Iid"::text) AS "ParameterValue"
   FROM "Iteration_REPLACE"."RequirementsContainerParameterValue_Data"() AS "RequirementsContainerParameterValue"
   JOIN "Iteration_REPLACE"."RequirementsContainer_Data"() AS "RequirementsContainer" ON "RequirementsContainerParameterValue"."Container" = "RequirementsContainer"."Iid"
   GROUP BY "RequirementsContainerParameterValue"."Container") AS "RequirementsContainer_ParameterValue" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."RequirementsContainerParameterValue_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParameterValue"."ValueTypeDictionary" || "RequirementsContainerParameterValue"."ValueTypeDictionary" AS "ValueTypeSet",
	"RequirementsContainerParameterValue"."Container",
	NULL::bigint AS "Sequence",
	"ParameterValue"."ParameterType",
	"ParameterValue"."Scale",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParameterValue_Data"() AS "ParameterValue" USING ("Iid")
  JOIN "Iteration_REPLACE"."RequirementsContainerParameterValue_Data"() AS "RequirementsContainerParameterValue" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."SimpleParameterizableThing_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "SimpleParameterizableThing"."ValueTypeDictionary" AS "ValueTypeSet",
	"SimpleParameterizableThing"."Owner",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("SimpleParameterizableThing_ParameterValue"."ParameterValue",'{}'::text[]) AS "ParameterValue",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."SimpleParameterizableThing_Data"() AS "SimpleParameterizableThing" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "SimpleParameterValue"."Container" AS "Iid", array_agg("SimpleParameterValue"."Iid"::text) AS "ParameterValue"
   FROM "Iteration_REPLACE"."SimpleParameterValue_Data"() AS "SimpleParameterValue"
   JOIN "Iteration_REPLACE"."SimpleParameterizableThing_Data"() AS "SimpleParameterizableThing" ON "SimpleParameterValue"."Container" = "SimpleParameterizableThing"."Iid"
   GROUP BY "SimpleParameterValue"."Container") AS "SimpleParameterizableThing_ParameterValue" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Requirement_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "SimpleParameterizableThing"."ValueTypeDictionary" || "Requirement"."ValueTypeDictionary" AS "ValueTypeSet",
	"Requirement"."Container",
	NULL::bigint AS "Sequence",
	"SimpleParameterizableThing"."Owner",
	"Requirement"."Group",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("SimpleParameterizableThing_ParameterValue"."ParameterValue",'{}'::text[]) AS "ParameterValue",
	COALESCE("Requirement_ParametricConstraint"."ParametricConstraint",'{}'::text[]) AS "ParametricConstraint",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Requirement_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."SimpleParameterizableThing_Data"() AS "SimpleParameterizableThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."Requirement_Data"() AS "Requirement" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Requirement" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."Requirement_Category_Data"() AS "Requirement_Category"
   JOIN "Iteration_REPLACE"."Requirement_Data"() AS "Requirement" ON "Requirement" = "Iid"
   GROUP BY "Requirement") AS "Requirement_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "SimpleParameterValue"."Container" AS "Iid", array_agg("SimpleParameterValue"."Iid"::text) AS "ParameterValue"
   FROM "Iteration_REPLACE"."SimpleParameterValue_Data"() AS "SimpleParameterValue"
   JOIN "Iteration_REPLACE"."SimpleParameterizableThing_Data"() AS "SimpleParameterizableThing" ON "SimpleParameterValue"."Container" = "SimpleParameterizableThing"."Iid"
   GROUP BY "SimpleParameterValue"."Container") AS "SimpleParameterizableThing_ParameterValue" USING ("Iid")
  LEFT JOIN (SELECT "ParametricConstraint"."Container" AS "Iid", ARRAY[array_agg("ParametricConstraint"."Sequence"::text), array_agg("ParametricConstraint"."Iid"::text)] AS "ParametricConstraint"
   FROM "Iteration_REPLACE"."ParametricConstraint_Data"() AS "ParametricConstraint"
   JOIN "Iteration_REPLACE"."Requirement_Data"() AS "Requirement" ON "ParametricConstraint"."Container" = "Requirement"."Iid"
   GROUP BY "ParametricConstraint"."Container") AS "Requirement_ParametricConstraint" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."SimpleParameterValue_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "SimpleParameterValue"."ValueTypeDictionary" AS "ValueTypeSet",
	"SimpleParameterValue"."Container",
	NULL::bigint AS "Sequence",
	"SimpleParameterValue"."ParameterType",
	"SimpleParameterValue"."Scale",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."SimpleParameterValue_Data"() AS "SimpleParameterValue" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ParametricConstraint_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ParametricConstraint"."ValueTypeDictionary" AS "ValueTypeSet",
	"ParametricConstraint"."Container",
	"ParametricConstraint"."Sequence",
	"ParametricConstraint"."TopExpression",
	COALESCE("ParametricConstraint_Expression"."Expression",'{}'::text[]) AS "Expression",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ParametricConstraint_Data"() AS "ParametricConstraint" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "BooleanExpression"."Container" AS "Iid", array_agg("BooleanExpression"."Iid"::text) AS "Expression"
   FROM "Iteration_REPLACE"."BooleanExpression_Data"() AS "BooleanExpression"
   JOIN "Iteration_REPLACE"."ParametricConstraint_Data"() AS "ParametricConstraint" ON "BooleanExpression"."Container" = "ParametricConstraint"."Iid"
   GROUP BY "BooleanExpression"."Container") AS "ParametricConstraint_Expression" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."BooleanExpression_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "BooleanExpression"."ValueTypeDictionary" AS "ValueTypeSet",
	"BooleanExpression"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."BooleanExpression_Data"() AS "BooleanExpression" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."OrExpression_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "BooleanExpression"."ValueTypeDictionary" || "OrExpression"."ValueTypeDictionary" AS "ValueTypeSet",
	"BooleanExpression"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("OrExpression_Term"."Term",'{}'::text[]) AS "Term"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."BooleanExpression_Data"() AS "BooleanExpression" USING ("Iid")
  JOIN "Iteration_REPLACE"."OrExpression_Data"() AS "OrExpression" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "OrExpression" AS "Iid", array_agg("Term"::text) AS "Term"
   FROM "Iteration_REPLACE"."OrExpression_Term_Data"() AS "OrExpression_Term"
   JOIN "Iteration_REPLACE"."OrExpression_Data"() AS "OrExpression" ON "OrExpression" = "Iid"
   GROUP BY "OrExpression") AS "OrExpression_Term" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."NotExpression_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "BooleanExpression"."ValueTypeDictionary" || "NotExpression"."ValueTypeDictionary" AS "ValueTypeSet",
	"BooleanExpression"."Container",
	NULL::bigint AS "Sequence",
	"NotExpression"."Term",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."BooleanExpression_Data"() AS "BooleanExpression" USING ("Iid")
  JOIN "Iteration_REPLACE"."NotExpression_Data"() AS "NotExpression" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."AndExpression_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "BooleanExpression"."ValueTypeDictionary" || "AndExpression"."ValueTypeDictionary" AS "ValueTypeSet",
	"BooleanExpression"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("AndExpression_Term"."Term",'{}'::text[]) AS "Term"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."BooleanExpression_Data"() AS "BooleanExpression" USING ("Iid")
  JOIN "Iteration_REPLACE"."AndExpression_Data"() AS "AndExpression" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "AndExpression" AS "Iid", array_agg("Term"::text) AS "Term"
   FROM "Iteration_REPLACE"."AndExpression_Term_Data"() AS "AndExpression_Term"
   JOIN "Iteration_REPLACE"."AndExpression_Data"() AS "AndExpression" ON "AndExpression" = "Iid"
   GROUP BY "AndExpression") AS "AndExpression_Term" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ExclusiveOrExpression_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "BooleanExpression"."ValueTypeDictionary" || "ExclusiveOrExpression"."ValueTypeDictionary" AS "ValueTypeSet",
	"BooleanExpression"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ExclusiveOrExpression_Term"."Term",'{}'::text[]) AS "Term"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."BooleanExpression_Data"() AS "BooleanExpression" USING ("Iid")
  JOIN "Iteration_REPLACE"."ExclusiveOrExpression_Data"() AS "ExclusiveOrExpression" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ExclusiveOrExpression" AS "Iid", array_agg("Term"::text) AS "Term"
   FROM "Iteration_REPLACE"."ExclusiveOrExpression_Term_Data"() AS "ExclusiveOrExpression_Term"
   JOIN "Iteration_REPLACE"."ExclusiveOrExpression_Data"() AS "ExclusiveOrExpression" ON "ExclusiveOrExpression" = "Iid"
   GROUP BY "ExclusiveOrExpression") AS "ExclusiveOrExpression_Term" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."RelationalExpression_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "BooleanExpression"."ValueTypeDictionary" || "RelationalExpression"."ValueTypeDictionary" AS "ValueTypeSet",
	"BooleanExpression"."Container",
	NULL::bigint AS "Sequence",
	"RelationalExpression"."ParameterType",
	"RelationalExpression"."Scale",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."BooleanExpression_Data"() AS "BooleanExpression" USING ("Iid")
  JOIN "Iteration_REPLACE"."RelationalExpression_Data"() AS "RelationalExpression" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."FileStore_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "FileStore"."ValueTypeDictionary" AS "ValueTypeSet",
	"FileStore"."Owner",
	COALESCE("FileStore_Folder"."Folder",'{}'::text[]) AS "Folder",
	COALESCE("FileStore_File"."File",'{}'::text[]) AS "File",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."FileStore_Data"() AS "FileStore" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Folder"."Container" AS "Iid", array_agg("Folder"."Iid"::text) AS "Folder"
   FROM "Iteration_REPLACE"."Folder_Data"() AS "Folder"
   JOIN "Iteration_REPLACE"."FileStore_Data"() AS "FileStore" ON "Folder"."Container" = "FileStore"."Iid"
   GROUP BY "Folder"."Container") AS "FileStore_Folder" USING ("Iid")
  LEFT JOIN (SELECT "File"."Container" AS "Iid", array_agg("File"."Iid"::text) AS "File"
   FROM "Iteration_REPLACE"."File_Data"() AS "File"
   JOIN "Iteration_REPLACE"."FileStore_Data"() AS "FileStore" ON "File"."Container" = "FileStore"."Iid"
   GROUP BY "File"."Container") AS "FileStore_File" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."DomainFileStore_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "FileStore"."ValueTypeDictionary" || "DomainFileStore"."ValueTypeDictionary" AS "ValueTypeSet",
	"DomainFileStore"."Container",
	NULL::bigint AS "Sequence",
	"FileStore"."Owner",
	COALESCE("FileStore_Folder"."Folder",'{}'::text[]) AS "Folder",
	COALESCE("FileStore_File"."File",'{}'::text[]) AS "File",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."FileStore_Data"() AS "FileStore" USING ("Iid")
  JOIN "Iteration_REPLACE"."DomainFileStore_Data"() AS "DomainFileStore" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Folder"."Container" AS "Iid", array_agg("Folder"."Iid"::text) AS "Folder"
   FROM "Iteration_REPLACE"."Folder_Data"() AS "Folder"
   JOIN "Iteration_REPLACE"."FileStore_Data"() AS "FileStore" ON "Folder"."Container" = "FileStore"."Iid"
   GROUP BY "Folder"."Container") AS "FileStore_Folder" USING ("Iid")
  LEFT JOIN (SELECT "File"."Container" AS "Iid", array_agg("File"."Iid"::text) AS "File"
   FROM "Iteration_REPLACE"."File_Data"() AS "File"
   JOIN "Iteration_REPLACE"."FileStore_Data"() AS "FileStore" ON "File"."Container" = "FileStore"."Iid"
   GROUP BY "File"."Container") AS "FileStore_File" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Folder_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "Folder"."ValueTypeDictionary" AS "ValueTypeSet",
	"Folder"."Container",
	NULL::bigint AS "Sequence",
	"Folder"."Creator",
	"Folder"."ContainingFolder",
	"Folder"."Owner",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."Folder_Data"() AS "Folder" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."File_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "File"."ValueTypeDictionary" AS "ValueTypeSet",
	"File"."Container",
	NULL::bigint AS "Sequence",
	"File"."LockedBy",
	"File"."Owner",
	COALESCE("File_FileRevision"."FileRevision",'{}'::text[]) AS "FileRevision",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("File_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."File_Data"() AS "File" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "File" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."File_Category_Data"() AS "File_Category"
   JOIN "Iteration_REPLACE"."File_Data"() AS "File" ON "File" = "Iid"
   GROUP BY "File") AS "File_Category" USING ("Iid")
  LEFT JOIN (SELECT "FileRevision"."Container" AS "Iid", array_agg("FileRevision"."Iid"::text) AS "FileRevision"
   FROM "Iteration_REPLACE"."FileRevision_Data"() AS "FileRevision"
   JOIN "Iteration_REPLACE"."File_Data"() AS "File" ON "FileRevision"."Container" = "File"."Iid"
   GROUP BY "FileRevision"."Container") AS "File_FileRevision" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."FileRevision_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "FileRevision"."ValueTypeDictionary" AS "ValueTypeSet",
	"FileRevision"."Container",
	NULL::bigint AS "Sequence",
	"FileRevision"."Creator",
	"FileRevision"."ContainingFolder",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("FileRevision_FileType"."FileType",'{}'::text[]) AS "FileType"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."FileRevision_Data"() AS "FileRevision" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "FileRevision" AS "Iid", ARRAY[array_agg("Sequence"::text), array_agg("FileType"::text)] AS "FileType"
   FROM "Iteration_REPLACE"."FileRevision_FileType_Data"() AS "FileRevision_FileType"
   JOIN "Iteration_REPLACE"."FileRevision_Data"() AS "FileRevision" ON "FileRevision" = "Iid"
   GROUP BY "FileRevision") AS "FileRevision_FileType" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ActualFiniteStateList_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ActualFiniteStateList"."ValueTypeDictionary" AS "ValueTypeSet",
	"ActualFiniteStateList"."Container",
	NULL::bigint AS "Sequence",
	"ActualFiniteStateList"."Owner",
	COALESCE("ActualFiniteStateList_ActualState"."ActualState",'{}'::text[]) AS "ActualState",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ActualFiniteStateList_PossibleFiniteStateList"."PossibleFiniteStateList",'{}'::text[]) AS "PossibleFiniteStateList",
	COALESCE("ActualFiniteStateList_ExcludeOption"."ExcludeOption",'{}'::text[]) AS "ExcludeOption"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ActualFiniteStateList_Data"() AS "ActualFiniteStateList" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ActualFiniteStateList" AS "Iid", ARRAY[array_agg("Sequence"::text), array_agg("PossibleFiniteStateList"::text)] AS "PossibleFiniteStateList"
   FROM "Iteration_REPLACE"."ActualFiniteStateList_PossibleFiniteStateList_Data"() AS "ActualFiniteStateList_PossibleFiniteStateList"
   JOIN "Iteration_REPLACE"."ActualFiniteStateList_Data"() AS "ActualFiniteStateList" ON "ActualFiniteStateList" = "Iid"
   GROUP BY "ActualFiniteStateList") AS "ActualFiniteStateList_PossibleFiniteStateList" USING ("Iid")
 LEFT JOIN (SELECT "ActualFiniteStateList" AS "Iid", array_agg("ExcludeOption"::text) AS "ExcludeOption"
   FROM "Iteration_REPLACE"."ActualFiniteStateList_ExcludeOption_Data"() AS "ActualFiniteStateList_ExcludeOption"
   JOIN "Iteration_REPLACE"."ActualFiniteStateList_Data"() AS "ActualFiniteStateList" ON "ActualFiniteStateList" = "Iid"
   GROUP BY "ActualFiniteStateList") AS "ActualFiniteStateList_ExcludeOption" USING ("Iid")
  LEFT JOIN (SELECT "ActualFiniteState"."Container" AS "Iid", array_agg("ActualFiniteState"."Iid"::text) AS "ActualState"
   FROM "Iteration_REPLACE"."ActualFiniteState_Data"() AS "ActualFiniteState"
   JOIN "Iteration_REPLACE"."ActualFiniteStateList_Data"() AS "ActualFiniteStateList" ON "ActualFiniteState"."Container" = "ActualFiniteStateList"."Iid"
   GROUP BY "ActualFiniteState"."Container") AS "ActualFiniteStateList_ActualState" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ActualFiniteState_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "ActualFiniteState"."ValueTypeDictionary" AS "ValueTypeSet",
	"ActualFiniteState"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ActualFiniteState_PossibleState"."PossibleState",'{}'::text[]) AS "PossibleState"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."ActualFiniteState_Data"() AS "ActualFiniteState" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ActualFiniteState" AS "Iid", array_agg("PossibleState"::text) AS "PossibleState"
   FROM "Iteration_REPLACE"."ActualFiniteState_PossibleState_Data"() AS "ActualFiniteState_PossibleState"
   JOIN "Iteration_REPLACE"."ActualFiniteState_Data"() AS "ActualFiniteState" ON "ActualFiniteState" = "Iid"
   GROUP BY "ActualFiniteState") AS "ActualFiniteState_PossibleState" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."RuleVerificationList_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "RuleVerificationList"."ValueTypeDictionary" AS "ValueTypeSet",
	"RuleVerificationList"."Container",
	NULL::bigint AS "Sequence",
	"RuleVerificationList"."Owner",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("RuleVerificationList_RuleVerification"."RuleVerification",'{}'::text[]) AS "RuleVerification",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."RuleVerificationList_Data"() AS "RuleVerificationList" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "RuleVerification"."Container" AS "Iid", ARRAY[array_agg("RuleVerification"."Sequence"::text), array_agg("RuleVerification"."Iid"::text)] AS "RuleVerification"
   FROM "Iteration_REPLACE"."RuleVerification_Data"() AS "RuleVerification"
   JOIN "Iteration_REPLACE"."RuleVerificationList_Data"() AS "RuleVerificationList" ON "RuleVerification"."Container" = "RuleVerificationList"."Iid"
   GROUP BY "RuleVerification"."Container") AS "RuleVerificationList_RuleVerification" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."RuleVerification_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "RuleVerification"."ValueTypeDictionary" AS "ValueTypeSet",
	"RuleVerification"."Container",
	"RuleVerification"."Sequence",
	COALESCE("RuleVerification_Violation"."Violation",'{}'::text[]) AS "Violation",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."RuleVerification_Data"() AS "RuleVerification" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "RuleViolation"."Container" AS "Iid", array_agg("RuleViolation"."Iid"::text) AS "Violation"
   FROM "Iteration_REPLACE"."RuleViolation_Data"() AS "RuleViolation"
   JOIN "Iteration_REPLACE"."RuleVerification_Data"() AS "RuleVerification" ON "RuleViolation"."Container" = "RuleVerification"."Iid"
   GROUP BY "RuleViolation"."Container") AS "RuleVerification_Violation" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."UserRuleVerification_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "RuleVerification"."ValueTypeDictionary" || "UserRuleVerification"."ValueTypeDictionary" AS "ValueTypeSet",
	"RuleVerification"."Container",
	"RuleVerification"."Sequence",
	"UserRuleVerification"."Rule",
	COALESCE("RuleVerification_Violation"."Violation",'{}'::text[]) AS "Violation",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."RuleVerification_Data"() AS "RuleVerification" USING ("Iid")
  JOIN "Iteration_REPLACE"."UserRuleVerification_Data"() AS "UserRuleVerification" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "RuleViolation"."Container" AS "Iid", array_agg("RuleViolation"."Iid"::text) AS "Violation"
   FROM "Iteration_REPLACE"."RuleViolation_Data"() AS "RuleViolation"
   JOIN "Iteration_REPLACE"."RuleVerification_Data"() AS "RuleVerification" ON "RuleViolation"."Container" = "RuleVerification"."Iid"
   GROUP BY "RuleViolation"."Container") AS "RuleVerification_Violation" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."RuleViolation_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "RuleViolation"."ValueTypeDictionary" AS "ValueTypeSet",
	"RuleViolation"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("RuleViolation_ViolatingThing"."ViolatingThing",'{}'::text[]) AS "ViolatingThing"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."RuleViolation_Data"() AS "RuleViolation" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "RuleViolation" AS "Iid", array_agg("ViolatingThing"::text) AS "ViolatingThing"
   FROM "Iteration_REPLACE"."RuleViolation_ViolatingThing_Data"() AS "RuleViolation_ViolatingThing"
   JOIN "Iteration_REPLACE"."RuleViolation_Data"() AS "RuleViolation" ON "RuleViolation" = "Iid"
   GROUP BY "RuleViolation") AS "RuleViolation_ViolatingThing" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."BuiltInRuleVerification_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "RuleVerification"."ValueTypeDictionary" || "BuiltInRuleVerification"."ValueTypeDictionary" AS "ValueTypeSet",
	"RuleVerification"."Container",
	"RuleVerification"."Sequence",
	COALESCE("RuleVerification_Violation"."Violation",'{}'::text[]) AS "Violation",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."RuleVerification_Data"() AS "RuleVerification" USING ("Iid")
  JOIN "Iteration_REPLACE"."BuiltInRuleVerification_Data"() AS "BuiltInRuleVerification" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "RuleViolation"."Container" AS "Iid", array_agg("RuleViolation"."Iid"::text) AS "Violation"
   FROM "Iteration_REPLACE"."RuleViolation_Data"() AS "RuleViolation"
   JOIN "Iteration_REPLACE"."RuleVerification_Data"() AS "RuleVerification" ON "RuleViolation"."Container" = "RuleVerification"."Iid"
   GROUP BY "RuleViolation"."Container") AS "RuleVerification_Violation" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Stakeholder_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "Stakeholder"."ValueTypeDictionary" AS "ValueTypeSet",
	"Stakeholder"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Stakeholder_StakeholderValue"."StakeholderValue",'{}'::text[]) AS "StakeholderValue",
	COALESCE("Stakeholder_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."Stakeholder_Data"() AS "Stakeholder" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Stakeholder" AS "Iid", array_agg("StakeholderValue"::text) AS "StakeholderValue"
   FROM "Iteration_REPLACE"."Stakeholder_StakeholderValue_Data"() AS "Stakeholder_StakeholderValue"
   JOIN "Iteration_REPLACE"."Stakeholder_Data"() AS "Stakeholder" ON "Stakeholder" = "Iid"
   GROUP BY "Stakeholder") AS "Stakeholder_StakeholderValue" USING ("Iid")
 LEFT JOIN (SELECT "Stakeholder" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."Stakeholder_Category_Data"() AS "Stakeholder_Category"
   JOIN "Iteration_REPLACE"."Stakeholder_Data"() AS "Stakeholder" ON "Stakeholder" = "Iid"
   GROUP BY "Stakeholder") AS "Stakeholder_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Goal_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "Goal"."ValueTypeDictionary" AS "ValueTypeSet",
	"Goal"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("Goal_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."Goal_Data"() AS "Goal" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "Goal" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."Goal_Category_Data"() AS "Goal_Category"
   JOIN "Iteration_REPLACE"."Goal_Data"() AS "Goal" ON "Goal" = "Iid"
   GROUP BY "Goal") AS "Goal_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."ValueGroup_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "ValueGroup"."ValueTypeDictionary" AS "ValueTypeSet",
	"ValueGroup"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("ValueGroup_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."ValueGroup_Data"() AS "ValueGroup" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "ValueGroup" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."ValueGroup_Category_Data"() AS "ValueGroup_Category"
   JOIN "Iteration_REPLACE"."ValueGroup_Data"() AS "ValueGroup" ON "ValueGroup" = "Iid"
   GROUP BY "ValueGroup") AS "ValueGroup_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."StakeholderValue_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "StakeholderValue"."ValueTypeDictionary" AS "ValueTypeSet",
	"StakeholderValue"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("StakeholderValue_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."StakeholderValue_Data"() AS "StakeholderValue" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "StakeholderValue" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."StakeholderValue_Category_Data"() AS "StakeholderValue_Category"
   JOIN "Iteration_REPLACE"."StakeholderValue_Data"() AS "StakeholderValue" ON "StakeholderValue" = "Iid"
   GROUP BY "StakeholderValue") AS "StakeholderValue_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."StakeHolderValueMap_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DefinedThing"."ValueTypeDictionary" || "StakeHolderValueMap"."ValueTypeDictionary" AS "ValueTypeSet",
	"StakeHolderValueMap"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("DefinedThing_Alias"."Alias",'{}'::text[]) AS "Alias",
	COALESCE("DefinedThing_Definition"."Definition",'{}'::text[]) AS "Definition",
	COALESCE("DefinedThing_HyperLink"."HyperLink",'{}'::text[]) AS "HyperLink",
	COALESCE("StakeHolderValueMap_Settings"."Settings",'{}'::text[]) AS "Settings",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain",
	COALESCE("StakeHolderValueMap_Goal"."Goal",'{}'::text[]) AS "Goal",
	COALESCE("StakeHolderValueMap_ValueGroup"."ValueGroup",'{}'::text[]) AS "ValueGroup",
	COALESCE("StakeHolderValueMap_StakeholderValue"."StakeholderValue",'{}'::text[]) AS "StakeholderValue",
	COALESCE("StakeHolderValueMap_Requirement"."Requirement",'{}'::text[]) AS "Requirement",
	COALESCE("StakeHolderValueMap_Category"."Category",'{}'::text[]) AS "Category"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."StakeHolderValueMap_Data"() AS "StakeHolderValueMap" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
 LEFT JOIN (SELECT "StakeHolderValueMap" AS "Iid", array_agg("Goal"::text) AS "Goal"
   FROM "Iteration_REPLACE"."StakeHolderValueMap_Goal_Data"() AS "StakeHolderValueMap_Goal"
   JOIN "Iteration_REPLACE"."StakeHolderValueMap_Data"() AS "StakeHolderValueMap" ON "StakeHolderValueMap" = "Iid"
   GROUP BY "StakeHolderValueMap") AS "StakeHolderValueMap_Goal" USING ("Iid")
 LEFT JOIN (SELECT "StakeHolderValueMap" AS "Iid", array_agg("ValueGroup"::text) AS "ValueGroup"
   FROM "Iteration_REPLACE"."StakeHolderValueMap_ValueGroup_Data"() AS "StakeHolderValueMap_ValueGroup"
   JOIN "Iteration_REPLACE"."StakeHolderValueMap_Data"() AS "StakeHolderValueMap" ON "StakeHolderValueMap" = "Iid"
   GROUP BY "StakeHolderValueMap") AS "StakeHolderValueMap_ValueGroup" USING ("Iid")
 LEFT JOIN (SELECT "StakeHolderValueMap" AS "Iid", array_agg("StakeholderValue"::text) AS "StakeholderValue"
   FROM "Iteration_REPLACE"."StakeHolderValueMap_StakeholderValue_Data"() AS "StakeHolderValueMap_StakeholderValue"
   JOIN "Iteration_REPLACE"."StakeHolderValueMap_Data"() AS "StakeHolderValueMap" ON "StakeHolderValueMap" = "Iid"
   GROUP BY "StakeHolderValueMap") AS "StakeHolderValueMap_StakeholderValue" USING ("Iid")
 LEFT JOIN (SELECT "StakeHolderValueMap" AS "Iid", array_agg("Requirement"::text) AS "Requirement"
   FROM "Iteration_REPLACE"."StakeHolderValueMap_Requirement_Data"() AS "StakeHolderValueMap_Requirement"
   JOIN "Iteration_REPLACE"."StakeHolderValueMap_Data"() AS "StakeHolderValueMap" ON "StakeHolderValueMap" = "Iid"
   GROUP BY "StakeHolderValueMap") AS "StakeHolderValueMap_Requirement" USING ("Iid")
 LEFT JOIN (SELECT "StakeHolderValueMap" AS "Iid", array_agg("Category"::text) AS "Category"
   FROM "Iteration_REPLACE"."StakeHolderValueMap_Category_Data"() AS "StakeHolderValueMap_Category"
   JOIN "Iteration_REPLACE"."StakeHolderValueMap_Data"() AS "StakeHolderValueMap" ON "StakeHolderValueMap" = "Iid"
   GROUP BY "StakeHolderValueMap") AS "StakeHolderValueMap_Category" USING ("Iid")
  LEFT JOIN (SELECT "Alias"."Container" AS "Iid", array_agg("Alias"."Iid"::text) AS "Alias"
   FROM "Iteration_REPLACE"."Alias_Data"() AS "Alias"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Alias"."Container" = "DefinedThing"."Iid"
   GROUP BY "Alias"."Container") AS "DefinedThing_Alias" USING ("Iid")
  LEFT JOIN (SELECT "Definition"."Container" AS "Iid", array_agg("Definition"."Iid"::text) AS "Definition"
   FROM "Iteration_REPLACE"."Definition_Data"() AS "Definition"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "Definition"."Container" = "DefinedThing"."Iid"
   GROUP BY "Definition"."Container") AS "DefinedThing_Definition" USING ("Iid")
  LEFT JOIN (SELECT "HyperLink"."Container" AS "Iid", array_agg("HyperLink"."Iid"::text) AS "HyperLink"
   FROM "Iteration_REPLACE"."HyperLink_Data"() AS "HyperLink"
   JOIN "Iteration_REPLACE"."DefinedThing_Data"() AS "DefinedThing" ON "HyperLink"."Container" = "DefinedThing"."Iid"
   GROUP BY "HyperLink"."Container") AS "DefinedThing_HyperLink" USING ("Iid")
  LEFT JOIN (SELECT "StakeHolderValueMapSettings"."Container" AS "Iid", array_agg("StakeHolderValueMapSettings"."Iid"::text) AS "Settings"
   FROM "Iteration_REPLACE"."StakeHolderValueMapSettings_Data"() AS "StakeHolderValueMapSettings"
   JOIN "Iteration_REPLACE"."StakeHolderValueMap_Data"() AS "StakeHolderValueMap" ON "StakeHolderValueMapSettings"."Container" = "StakeHolderValueMap"."Iid"
   GROUP BY "StakeHolderValueMapSettings"."Container") AS "StakeHolderValueMap_Settings" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."StakeHolderValueMapSettings_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "StakeHolderValueMapSettings"."ValueTypeDictionary" AS "ValueTypeSet",
	"StakeHolderValueMapSettings"."Container",
	NULL::bigint AS "Sequence",
	"StakeHolderValueMapSettings"."GoalToValueGroupRelationship",
	"StakeHolderValueMapSettings"."ValueGroupToStakeholderValueRelationship",
	"StakeHolderValueMapSettings"."StakeholderValueToRequirementRelationship",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."StakeHolderValueMapSettings_Data"() AS "StakeHolderValueMapSettings" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."DiagramThingBase_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" AS "ValueTypeSet",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."DiagrammingStyle_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "DiagrammingStyle"."ValueTypeDictionary" AS "ValueTypeSet",
	"DiagrammingStyle"."FillColor",
	"DiagrammingStyle"."StrokeColor",
	"DiagrammingStyle"."FontColor",
	COALESCE("DiagrammingStyle_UsedColor"."UsedColor",'{}'::text[]) AS "UsedColor",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagrammingStyle_Data"() AS "DiagrammingStyle" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Color"."Container" AS "Iid", array_agg("Color"."Iid"::text) AS "UsedColor"
   FROM "Iteration_REPLACE"."Color_Data"() AS "Color"
   JOIN "Iteration_REPLACE"."DiagrammingStyle_Data"() AS "DiagrammingStyle" ON "Color"."Container" = "DiagrammingStyle"."Iid"
   GROUP BY "Color"."Container") AS "DiagrammingStyle_UsedColor" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."SharedStyle_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "DiagrammingStyle"."ValueTypeDictionary" || "SharedStyle"."ValueTypeDictionary" AS "ValueTypeSet",
	"SharedStyle"."Container",
	NULL::bigint AS "Sequence",
	"DiagrammingStyle"."FillColor",
	"DiagrammingStyle"."StrokeColor",
	"DiagrammingStyle"."FontColor",
	COALESCE("DiagrammingStyle_UsedColor"."UsedColor",'{}'::text[]) AS "UsedColor",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagrammingStyle_Data"() AS "DiagrammingStyle" USING ("Iid")
  JOIN "Iteration_REPLACE"."SharedStyle_Data"() AS "SharedStyle" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Color"."Container" AS "Iid", array_agg("Color"."Iid"::text) AS "UsedColor"
   FROM "Iteration_REPLACE"."Color_Data"() AS "Color"
   JOIN "Iteration_REPLACE"."DiagrammingStyle_Data"() AS "DiagrammingStyle" ON "Color"."Container" = "DiagrammingStyle"."Iid"
   GROUP BY "Color"."Container") AS "DiagrammingStyle_UsedColor" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Color_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "Color"."ValueTypeDictionary" AS "ValueTypeSet",
	"Color"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."Color_Data"() AS "Color" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."DiagramElementContainer_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "DiagramElementContainer"."ValueTypeDictionary" AS "ValueTypeSet",
	COALESCE("DiagramElementContainer_DiagramElement"."DiagramElement",'{}'::text[]) AS "DiagramElement",
	COALESCE("DiagramElementContainer_Bounds"."Bounds",'{}'::text[]) AS "Bounds",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "DiagramElementThing"."Container" AS "Iid", array_agg("DiagramElementThing"."Iid"::text) AS "DiagramElement"
   FROM "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "DiagramElementThing"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "DiagramElementThing"."Container") AS "DiagramElementContainer_DiagramElement" USING ("Iid")
  LEFT JOIN (SELECT "Bounds"."Container" AS "Iid", array_agg("Bounds"."Iid"::text) AS "Bounds"
   FROM "Iteration_REPLACE"."Bounds_Data"() AS "Bounds"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "Bounds"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "Bounds"."Container") AS "DiagramElementContainer_Bounds" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."DiagramCanvas_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "DiagramElementContainer"."ValueTypeDictionary" || "DiagramCanvas"."ValueTypeDictionary" AS "ValueTypeSet",
	"DiagramCanvas"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("DiagramElementContainer_DiagramElement"."DiagramElement",'{}'::text[]) AS "DiagramElement",
	COALESCE("DiagramElementContainer_Bounds"."Bounds",'{}'::text[]) AS "Bounds",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramCanvas_Data"() AS "DiagramCanvas" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "DiagramElementThing"."Container" AS "Iid", array_agg("DiagramElementThing"."Iid"::text) AS "DiagramElement"
   FROM "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "DiagramElementThing"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "DiagramElementThing"."Container") AS "DiagramElementContainer_DiagramElement" USING ("Iid")
  LEFT JOIN (SELECT "Bounds"."Container" AS "Iid", array_agg("Bounds"."Iid"::text) AS "Bounds"
   FROM "Iteration_REPLACE"."Bounds_Data"() AS "Bounds"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "Bounds"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "Bounds"."Container") AS "DiagramElementContainer_Bounds" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."DiagramElementThing_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "DiagramElementContainer"."ValueTypeDictionary" || "DiagramElementThing"."ValueTypeDictionary" AS "ValueTypeSet",
	"DiagramElementThing"."Container",
	NULL::bigint AS "Sequence",
	"DiagramElementThing"."DepictedThing",
	"DiagramElementThing"."SharedStyle",
	COALESCE("DiagramElementContainer_DiagramElement"."DiagramElement",'{}'::text[]) AS "DiagramElement",
	COALESCE("DiagramElementContainer_Bounds"."Bounds",'{}'::text[]) AS "Bounds",
	COALESCE("DiagramElementThing_LocalStyle"."LocalStyle",'{}'::text[]) AS "LocalStyle",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "DiagramElementThing"."Container" AS "Iid", array_agg("DiagramElementThing"."Iid"::text) AS "DiagramElement"
   FROM "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "DiagramElementThing"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "DiagramElementThing"."Container") AS "DiagramElementContainer_DiagramElement" USING ("Iid")
  LEFT JOIN (SELECT "Bounds"."Container" AS "Iid", array_agg("Bounds"."Iid"::text) AS "Bounds"
   FROM "Iteration_REPLACE"."Bounds_Data"() AS "Bounds"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "Bounds"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "Bounds"."Container") AS "DiagramElementContainer_Bounds" USING ("Iid")
  LEFT JOIN (SELECT "OwnedStyle"."Container" AS "Iid", array_agg("OwnedStyle"."Iid"::text) AS "LocalStyle"
   FROM "Iteration_REPLACE"."OwnedStyle_Data"() AS "OwnedStyle"
   JOIN "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing" ON "OwnedStyle"."Container" = "DiagramElementThing"."Iid"
   GROUP BY "OwnedStyle"."Container") AS "DiagramElementThing_LocalStyle" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."DiagramEdge_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "DiagramElementContainer"."ValueTypeDictionary" || "DiagramElementThing"."ValueTypeDictionary" || "DiagramEdge"."ValueTypeDictionary" AS "ValueTypeSet",
	"DiagramElementThing"."Container",
	NULL::bigint AS "Sequence",
	"DiagramElementThing"."DepictedThing",
	"DiagramElementThing"."SharedStyle",
	"DiagramEdge"."Source",
	"DiagramEdge"."Target",
	COALESCE("DiagramElementContainer_DiagramElement"."DiagramElement",'{}'::text[]) AS "DiagramElement",
	COALESCE("DiagramElementContainer_Bounds"."Bounds",'{}'::text[]) AS "Bounds",
	COALESCE("DiagramElementThing_LocalStyle"."LocalStyle",'{}'::text[]) AS "LocalStyle",
	COALESCE("DiagramEdge_Point"."Point",'{}'::text[]) AS "Point",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramEdge_Data"() AS "DiagramEdge" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "DiagramElementThing"."Container" AS "Iid", array_agg("DiagramElementThing"."Iid"::text) AS "DiagramElement"
   FROM "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "DiagramElementThing"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "DiagramElementThing"."Container") AS "DiagramElementContainer_DiagramElement" USING ("Iid")
  LEFT JOIN (SELECT "Bounds"."Container" AS "Iid", array_agg("Bounds"."Iid"::text) AS "Bounds"
   FROM "Iteration_REPLACE"."Bounds_Data"() AS "Bounds"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "Bounds"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "Bounds"."Container") AS "DiagramElementContainer_Bounds" USING ("Iid")
  LEFT JOIN (SELECT "OwnedStyle"."Container" AS "Iid", array_agg("OwnedStyle"."Iid"::text) AS "LocalStyle"
   FROM "Iteration_REPLACE"."OwnedStyle_Data"() AS "OwnedStyle"
   JOIN "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing" ON "OwnedStyle"."Container" = "DiagramElementThing"."Iid"
   GROUP BY "OwnedStyle"."Container") AS "DiagramElementThing_LocalStyle" USING ("Iid")
  LEFT JOIN (SELECT "Point"."Container" AS "Iid", ARRAY[array_agg("Point"."Sequence"::text), array_agg("Point"."Iid"::text)] AS "Point"
   FROM "Iteration_REPLACE"."Point_Data"() AS "Point"
   JOIN "Iteration_REPLACE"."DiagramEdge_Data"() AS "DiagramEdge" ON "Point"."Container" = "DiagramEdge"."Iid"
   GROUP BY "Point"."Container") AS "DiagramEdge_Point" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Bounds_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "Bounds"."ValueTypeDictionary" AS "ValueTypeSet",
	"Bounds"."Container",
	NULL::bigint AS "Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."Bounds_Data"() AS "Bounds" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."OwnedStyle_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "DiagrammingStyle"."ValueTypeDictionary" || "OwnedStyle"."ValueTypeDictionary" AS "ValueTypeSet",
	"OwnedStyle"."Container",
	NULL::bigint AS "Sequence",
	"DiagrammingStyle"."FillColor",
	"DiagrammingStyle"."StrokeColor",
	"DiagrammingStyle"."FontColor",
	COALESCE("DiagrammingStyle_UsedColor"."UsedColor",'{}'::text[]) AS "UsedColor",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagrammingStyle_Data"() AS "DiagrammingStyle" USING ("Iid")
  JOIN "Iteration_REPLACE"."OwnedStyle_Data"() AS "OwnedStyle" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "Color"."Container" AS "Iid", array_agg("Color"."Iid"::text) AS "UsedColor"
   FROM "Iteration_REPLACE"."Color_Data"() AS "Color"
   JOIN "Iteration_REPLACE"."DiagrammingStyle_Data"() AS "DiagrammingStyle" ON "Color"."Container" = "DiagrammingStyle"."Iid"
   GROUP BY "Color"."Container") AS "DiagrammingStyle_UsedColor" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."Point_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "Point"."ValueTypeDictionary" AS "ValueTypeSet",
	"Point"."Container",
	"Point"."Sequence",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."Point_Data"() AS "Point" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."DiagramShape_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "DiagramElementContainer"."ValueTypeDictionary" || "DiagramElementThing"."ValueTypeDictionary" || "DiagramShape"."ValueTypeDictionary" AS "ValueTypeSet",
	"DiagramElementThing"."Container",
	NULL::bigint AS "Sequence",
	"DiagramElementThing"."DepictedThing",
	"DiagramElementThing"."SharedStyle",
	COALESCE("DiagramElementContainer_DiagramElement"."DiagramElement",'{}'::text[]) AS "DiagramElement",
	COALESCE("DiagramElementContainer_Bounds"."Bounds",'{}'::text[]) AS "Bounds",
	COALESCE("DiagramElementThing_LocalStyle"."LocalStyle",'{}'::text[]) AS "LocalStyle",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramShape_Data"() AS "DiagramShape" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "DiagramElementThing"."Container" AS "Iid", array_agg("DiagramElementThing"."Iid"::text) AS "DiagramElement"
   FROM "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "DiagramElementThing"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "DiagramElementThing"."Container") AS "DiagramElementContainer_DiagramElement" USING ("Iid")
  LEFT JOIN (SELECT "Bounds"."Container" AS "Iid", array_agg("Bounds"."Iid"::text) AS "Bounds"
   FROM "Iteration_REPLACE"."Bounds_Data"() AS "Bounds"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "Bounds"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "Bounds"."Container") AS "DiagramElementContainer_Bounds" USING ("Iid")
  LEFT JOIN (SELECT "OwnedStyle"."Container" AS "Iid", array_agg("OwnedStyle"."Iid"::text) AS "LocalStyle"
   FROM "Iteration_REPLACE"."OwnedStyle_Data"() AS "OwnedStyle"
   JOIN "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing" ON "OwnedStyle"."Container" = "DiagramElementThing"."Iid"
   GROUP BY "OwnedStyle"."Container") AS "DiagramElementThing_LocalStyle" USING ("Iid");

CREATE VIEW "Iteration_REPLACE"."DiagramObject_View" AS
 SELECT "Thing"."Iid", "Thing"."ValueTypeDictionary" || "DiagramThingBase"."ValueTypeDictionary" || "DiagramElementContainer"."ValueTypeDictionary" || "DiagramElementThing"."ValueTypeDictionary" || "DiagramShape"."ValueTypeDictionary" || "DiagramObject"."ValueTypeDictionary" AS "ValueTypeSet",
	"DiagramElementThing"."Container",
	NULL::bigint AS "Sequence",
	"DiagramElementThing"."DepictedThing",
	"DiagramElementThing"."SharedStyle",
	COALESCE("DiagramElementContainer_DiagramElement"."DiagramElement",'{}'::text[]) AS "DiagramElement",
	COALESCE("DiagramElementContainer_Bounds"."Bounds",'{}'::text[]) AS "Bounds",
	COALESCE("DiagramElementThing_LocalStyle"."LocalStyle",'{}'::text[]) AS "LocalStyle",
	COALESCE("Thing_ExcludedPerson"."ExcludedPerson",'{}'::text[]) AS "ExcludedPerson",
	COALESCE("Thing_ExcludedDomain"."ExcludedDomain",'{}'::text[]) AS "ExcludedDomain"
  FROM "Iteration_REPLACE"."Thing_Data"() AS "Thing"
  JOIN "Iteration_REPLACE"."DiagramThingBase_Data"() AS "DiagramThingBase" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramShape_Data"() AS "DiagramShape" USING ("Iid")
  JOIN "Iteration_REPLACE"."DiagramObject_Data"() AS "DiagramObject" USING ("Iid")
  LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedPerson"::text) AS "ExcludedPerson"
   FROM "Iteration_REPLACE"."Thing_ExcludedPerson_Data"() AS "Thing_ExcludedPerson"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedPerson" USING ("Iid")
 LEFT JOIN (SELECT "Thing" AS "Iid", array_agg("ExcludedDomain"::text) AS "ExcludedDomain"
   FROM "Iteration_REPLACE"."Thing_ExcludedDomain_Data"() AS "Thing_ExcludedDomain"
   JOIN "Iteration_REPLACE"."Thing_Data"() AS "Thing" ON "Thing" = "Iid"
   GROUP BY "Thing") AS "Thing_ExcludedDomain" USING ("Iid")
  LEFT JOIN (SELECT "DiagramElementThing"."Container" AS "Iid", array_agg("DiagramElementThing"."Iid"::text) AS "DiagramElement"
   FROM "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "DiagramElementThing"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "DiagramElementThing"."Container") AS "DiagramElementContainer_DiagramElement" USING ("Iid")
  LEFT JOIN (SELECT "Bounds"."Container" AS "Iid", array_agg("Bounds"."Iid"::text) AS "Bounds"
   FROM "Iteration_REPLACE"."Bounds_Data"() AS "Bounds"
   JOIN "Iteration_REPLACE"."DiagramElementContainer_Data"() AS "DiagramElementContainer" ON "Bounds"."Container" = "DiagramElementContainer"."Iid"
   GROUP BY "Bounds"."Container") AS "DiagramElementContainer_Bounds" USING ("Iid")
  LEFT JOIN (SELECT "OwnedStyle"."Container" AS "Iid", array_agg("OwnedStyle"."Iid"::text) AS "LocalStyle"
   FROM "Iteration_REPLACE"."OwnedStyle_Data"() AS "OwnedStyle"
   JOIN "Iteration_REPLACE"."DiagramElementThing_Data"() AS "DiagramElementThing" ON "OwnedStyle"."Container" = "DiagramElementThing"."Iid"
   GROUP BY "OwnedStyle"."Container") AS "DiagramElementThing_LocalStyle" USING ("Iid");
