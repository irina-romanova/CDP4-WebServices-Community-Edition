﻿// --------------------------------------------------------------------------------------------------------------------
// <copyright file="QuantityKindFactorService.cs" company="RHEA System S.A.">
//   Copyright (c) 2016 RHEA System S.A.
// </copyright>
// <summary>
//   This is an auto-generated class. Any manual changes on this file will be overwritten!
// </summary>
// --------------------------------------------------------------------------------------------------------------------

namespace CDP4WebServices.API.Services
{
    using System;
    using System.Collections.Generic;
    using System.Linq;
	using System.Security;

    using CDP4Common.DTO;
    
    using CDP4Orm.Dao;
 
    using CDP4WebServices.API.Services.Authorization;
 
    using Npgsql;
 
    /// <summary>
    /// The QuantityKindFactor Service which uses the ORM layer to interact with the data model.
    /// </summary>
    public sealed partial class QuantityKindFactorService : ServiceBase, IQuantityKindFactorService
    {
        /// <summary>
        /// Gets or sets the quantityKindFactor dao.
        /// </summary>
        public IQuantityKindFactorDao QuantityKindFactorDao { get; set; }

        /// <summary>
        /// Get the requested data from the ORM layer.
        /// </summary>
        /// <param name="transaction">
        /// The transaction object.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) where the requested resource is stored.
        /// </param>
        /// <param name="ids">
        /// Ids to retrieve from the database.
        /// </param>
        /// <param name="containerSecurityContext">
        /// The security context of the container instance.
        /// </param>
        /// <returns>
        /// List of instances of <see cref="QuantityKindFactor"/>.
        /// </returns>
        public IEnumerable<Thing> Get(NpgsqlTransaction transaction, string partition, IEnumerable<Guid> ids, ISecurityContext containerSecurityContext)
        {
            return this.RequestUtils.QueryParameters.ExtentDeep
                       ? this.GetDeep(transaction, partition, ids, containerSecurityContext)
                       : this.GetShallow(transaction, partition, ids, containerSecurityContext);
        }

        /// <summary>
        /// Add the supplied value to the association link table indicated by the supplied property name.
        /// </summary>
        /// <param name="transaction">
        /// The current transaction to the database.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) where the requested resource will be stored.
        /// </param>
        /// <param name="propertyName">
        /// The association property name that will be persisted.
        /// </param>
        /// <param name="iid">
        /// The <see cref="QuantityKindFactor"/> id that will be the source for each link table record.
        /// </param>
        /// <param name="value">
        /// A value for which a link table record will be created.
        /// </param>
        /// <returns>
        /// True if the link was created.
        /// </returns>
        public bool AddToCollectionProperty(NpgsqlTransaction transaction, string partition, string propertyName, Guid iid, object value)
        {
            return this.QuantityKindFactorDao.AddToCollectionProperty(transaction, partition, propertyName, iid, value);
        }

        /// <summary>
        /// Remove the supplied value from the association property as indicated by the supplied property name.
        /// </summary>
        /// <param name="transaction">
        /// The current transaction to the database.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) from where the requested resource will be removed.
        /// </param>
        /// <param name="propertyName">
        /// The association property from where the supplied value will be removed.
        /// </param>
        /// <param name="iid">
        /// The <see cref="QuantityKindFactor"/> id that is the source of the link table records.
        /// </param>
        /// <param name="value">
        /// A value for which the link table record will be removed.
        /// </param>
        /// <returns>
        /// True if the link was removed.
        /// </returns>
        public bool DeleteFromCollectionProperty(NpgsqlTransaction transaction, string partition, string propertyName, Guid iid, object value)
        {
            return this.QuantityKindFactorDao.DeleteFromCollectionProperty(transaction, partition, propertyName, iid, value);
        }

        /// <summary>
        /// Reorder the supplied value collection of the association link table indicated by the supplied property name.
        /// </summary>
        /// <param name="transaction">
        /// The current transaction to the database.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) where the requested resource order will be updated.
        /// </param>
        /// <param name="propertyName">
        /// The association property name that will be reordered.
        /// </param>
        /// <param name="iid">
        /// The <see cref="QuantityKindFactor"/> id that is the source for the reordered link table record.
        /// </param>
        /// <param name="orderUpdate">
        /// The order update information containing the new order key.
        /// </param>
        /// <returns>
        /// True if the link was created.
        /// </returns>
        public bool ReorderCollectionProperty(NpgsqlTransaction transaction, string partition, string propertyName, Guid iid, CDP4Common.Types.OrderedItem orderUpdate)
        {
            return this.QuantityKindFactorDao.ReorderCollectionProperty(transaction, partition, propertyName, iid, orderUpdate);
        }

        /// <summary>
        /// Update the containment order as indicated by the supplied orderedItem.
        /// </summary>
        /// <param name="transaction">
        /// The current transaction to the database.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) where the requested resource order will be updated.
        /// </param>
        /// <param name="orderedItem">
        /// The order update information containing the new order key.
        /// </param>
        /// <returns>
        /// True if the contained item was successfully reordered.
        /// </returns>
        public bool ReorderContainment(NpgsqlTransaction transaction, string partition, CDP4Common.Types.OrderedItem orderedItem)
        {
            return this.QuantityKindFactorDao.ReorderContainment(transaction, partition, orderedItem);
        }

        /// <summary>
        /// Delete the supplied DTO instance.
        /// </summary>
        /// <param name="transaction">
        /// The transaction to the database.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) from where the requested resource will be removed.
        /// </param>
        /// <param name="thing">
        /// The <see cref="QuantityKindFactor"/> to delete.
        /// </param>
        /// <param name="container">
        /// The container instance of the DTO to be removed.
        /// </param>
        /// <returns>
        /// True if the removal was successful.
        /// </returns>
        public bool DeleteConcept(NpgsqlTransaction transaction, string partition, Thing thing, Thing container = null)
        {
            if (!this.IsInstanceModifyAllowed(transaction, thing, partition, DeleteOperation))
            {
                throw new SecurityException("The person " + this.PermissionService.Credentials.Person.UserName + " does not have an appropriate delete permission for " + thing.GetType().Name + ".");
            }

            return this.QuantityKindFactorDao.Delete(transaction, partition, thing.Iid);
        }

        /// <summary>
        /// Update the supplied DTO instance.
        /// </summary>
        /// <param name="transaction">
        /// The transaction object.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) where the requested resource will be updated.
        /// </param>
        /// <param name="thing">
        /// The Thing to update.
        /// </param>
        /// <param name="container">
        /// The container instance of the DTO to be updated.
        /// </param>
        /// <returns>
        /// True if the update was successful.
        /// </returns>
        public bool UpdateConcept(NpgsqlTransaction transaction, string partition, Thing thing, Thing container)
        {
            if (!this.IsInstanceModifyAllowed(transaction, thing, partition, UpdateOperation))
            {
                throw new SecurityException("The person " + this.PermissionService.Credentials.Person.UserName + " does not have an appropriate update permission for " + thing.GetType().Name + ".");
            }

            var quantityKindFactor = thing as QuantityKindFactor;
            return this.QuantityKindFactorDao.Update(transaction, partition, quantityKindFactor, container);
        }

        /// <summary>
        /// Persist the supplied DTO instance.
        /// </summary>
        /// <param name="transaction">
        /// The transaction object.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) where the requested resource will be stored.
        /// </param>
        /// <param name="thing">
        /// The Thing to create.
        /// </param>
        /// <param name="container">
        /// The container instance of the DTO to be persisted.
        /// </param>
        /// <param name="sequence">
        /// The order sequence used to persist this instance. Default is not used (-1).
        /// </param>
        /// <returns>
        /// True if the persistence was successful.
        /// </returns>
        public bool CreateConcept(NpgsqlTransaction transaction, string partition, Thing thing, Thing container, long sequence = -1)
        {
            if (!this.IsInstanceModifyAllowed(transaction, thing, partition, CreateOperation))
            {
                throw new SecurityException("The person " + this.PermissionService.Credentials.Person.UserName + " does not have an appropriate create permission for " + thing.GetType().Name + ".");
            }

            var quantityKindFactor = thing as QuantityKindFactor;
            return this.QuantityKindFactorDao.Write(transaction, partition, quantityKindFactor, sequence, container);
        }

        /// <summary>
        /// Get the requested data from the ORM layer.
        /// </summary>
        /// <param name="transaction">
        /// The transaction object.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) where the requested resource is stored.
        /// </param>
        /// <param name="ids">
        /// Ids to retrieve from the database.
        /// </param>
        /// <param name="containerSecurityContext">
        /// The security context of the container instance.
        /// </param>
        /// <returns>
        /// List of instances of <see cref="QuantityKindFactor"/>.
        /// </returns>
        public IEnumerable<Thing> GetShallow(NpgsqlTransaction transaction, string partition, IEnumerable<Guid> ids, ISecurityContext containerSecurityContext)
        {
            var idFilter = ids == null ? null : ids.ToArray();
            var authorizedContext = this.AuthorizeReadRequest("QuantityKindFactor", containerSecurityContext, partition);
            var isAllowed = authorizedContext.ContainerReadAllowed && this.BeforeGet(transaction, partition, idFilter);
            if (!isAllowed || (idFilter != null && !idFilter.Any()))
            {
                return Enumerable.Empty<Thing>();
            }

            var quantityKindFactorColl = new List<Thing>(this.QuantityKindFactorDao.Read(transaction, partition, idFilter, this.TransactionManager.IsCachedDtoReadEnabled(transaction)));

            return this.AfterGet(quantityKindFactorColl, transaction, partition, idFilter);
        }

        /// <summary>
        /// Get the requested data from the ORM layer by chaining the containment properties.
        /// </summary>
        /// <param name="transaction">
        /// The transaction object.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) where the requested resource is stored.
        /// </param>
        /// <param name="ids">
        /// Ids to retrieve from the database.
        /// </param>
        /// <param name="containerSecurityContext">
        /// The security context of the container instance.
        /// </param>
        /// <returns>
        /// List of instances of <see cref="QuantityKindFactor"/>.
        /// </returns>
        public IEnumerable<Thing> GetDeep(NpgsqlTransaction transaction, string partition, IEnumerable<Guid> ids, ISecurityContext containerSecurityContext)
        {
            var idFilter = ids == null ? null : ids.ToArray();
            if (idFilter != null && !idFilter.Any())
            {
                return Enumerable.Empty<Thing>();
            }

            return this.GetShallow(transaction, partition, idFilter, containerSecurityContext);
         }

        /// <summary>
        /// Execute additional logic after each get function call.
        /// </summary>
        /// <param name="resultCollection">
        /// An instance collection that was retrieved from the persistence layer.
        /// </param>
        /// <param name="transaction">
        /// The current transaction to the database.
        /// </param>
        /// <param name="partition">
        /// The database partition (schema) from which the requested resource is to be retrieved.
        /// </param>
        /// <param name="ids">
        /// Ids to retrieve from the database.
        /// </param>
        /// <param name="includeReferenceData">
        /// Control flag to indicate if reference library data should be retrieved extent=deep or extent=shallow.
        /// </param>
        /// <returns>
        /// A post filtered instance of the passed in resultCollection.
        /// </returns>
        public override IEnumerable<Thing> AfterGet(IEnumerable<Thing> resultCollection, NpgsqlTransaction transaction, string partition, IEnumerable<Guid> ids, bool includeReferenceData = false)
        {
            var filteredCollection = new List<Thing>();
            foreach (var thing in resultCollection)
            {
                if (this.IsInstanceReadAllowed(transaction, thing, partition))
                {
                    filteredCollection.Add(thing);
                }
                else
                {
                    Logger.Info("The person " + this.PermissionService.Credentials.Person.UserName + " does not have a read permission for " + thing.GetType().Name + ".");
                }
            }
            
            return filteredCollection;
        }

    }
}
